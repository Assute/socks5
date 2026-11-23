#!/usr/bin/env bash
# ============================================================
#  SOCKS5 服务管理脚本 v3.8   (Dante SOCKS5)
#
#  系统: Debian / Ubuntu (apt)   CentOS / Rocky / Alma / RHEL (dnf|yum)
#  功能: 安装 · 修改 · 卸载 · 限速(tc HTB) · 状态 · 日志 · 统计
#
#  用法:  bash install.sh            # 交互菜单
#         bash install.sh install    # 直接安装
#         bash install.sh help
# ============================================================

CONFIG_DIR="/etc/socks5-manager"
STATS_FILE="$CONFIG_DIR/usage_stats.log"
INSTALL_INFO="$CONFIG_DIR/install_info.conf"
LIMIT_CONF="$CONFIG_DIR/limit.conf"

DANTE_CONF="/etc/danted.conf"
DANTE_BIN="/usr/sbin/danted"
S5_UNIT="/etc/systemd/system/danted.service"
SHAPING_UNIT="/etc/systemd/system/socks5-shaping.service"
SELF_PATH="/usr/local/sbin/socks5"
SELF_URL="https://raw.githubusercontent.com/Assute/socks5/main/install.sh"
# 升级检查优先走 API：raw.githubusercontent 走 Fastly 缓存，刚推完会拿到旧内容
SELF_API_URL="https://api.github.com/repos/Assute/socks5/contents/install.sh?ref=main"
LOG_FILE="/var/log/danted.log"
LOGROTATE_FILE="/etc/logrotate.d/socks5-danted"
IFB_DEV="ifb0"
SCRIPT_VERSION="3.8"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'; BOLD='\033[1m'
NC='\033[0m'

# ---------- 输出 ----------
log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_success() { echo -e "${CYAN}[OK]${NC} $*"; }
log_step()    { echo -e "${BLUE}==>${NC} ${BOLD}$*${NC}"; }
die()         { log_error "$*"; exit 1; }
hr()          { echo "--------------------------------------------------"; }

log_usage() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$STATS_FILE" 2>/dev/null
}

# ---------- 基础工具 ----------
need_root() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] && die "请使用 root 权限运行：sudo bash $0"
}

detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS="rhel"
        if command -v dnf >/dev/null 2>&1; then PM="dnf"; else PM="yum"; fi
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"; PM="apt-get"
    elif [[ -f /etc/alpine-release ]]; then
        die "Alpine 不支持（dante 的 systemd/PAM 依赖不匹配），请用 Debian/Ubuntu/CentOS"
    else
        die "不支持的系统：$(uname -a)"
    fi
    log_info "系统类型: $OS  (包管理器: $PM)"
}

pkg_install() {
    if [[ "$OS" == "rhel" ]]; then
        $PM install -y "$@"
    else
        DEBIAN_FRONTEND=noninteractive $PM install -y "$@"
    fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

get_iface() {
    local i
    i=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$i" ]] && i=$(ip -4 route show default 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -n1)
    [[ -z "$i" ]] && i=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
    printf '%s' "$i"
}

# 从安装信息里读网卡名（不 source，避免污染当前变量）
installed_iface() {
    [[ -f "$INSTALL_INFO" ]] || return 0
    sed -n 's/^INTERFACE=//p' "$INSTALL_INFO" 2>/dev/null | tr -d "'\"" | head -n1
}

# 探测网卡，失败则回落到安装时记录的那块
resolve_iface() {
    local i
    i=$(get_iface)
    [[ -z "$i" ]] && i=$(installed_iface)
    printf '%s' "$i"
}

get_public_ip() {
    local ip=""
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
        ip=$(curl -s --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
        [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s' "$ip"; return; }
    done
    ip=$(ip -4 addr show scope global 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1)
    printf '%s' "${ip:-0.0.0.0}"
}

gen_pass() { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16; }

# grep -c 在计数为 0 时退出码是 1，直接 `|| echo 0` 会输出两行，必须这样包一层
count_in() {
    local n
    n=$(grep -c -- "$1" "$2" 2>/dev/null)
    printf '%s' "${n:-0}"
}

# 输出占用指定端口的监听行（含进程信息）
# 注意：ss 加 -p 后行尾是 users:(("danted",pid=...))，
# 所以必须按第 4 列（本地地址）匹配，不能拿 $ 锚在整行末尾
port_listeners() {
    local p="$1"
    if has_cmd ss; then
        ss -H -ltnp 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")'
    elif has_cmd netstat; then
        netstat -ltnp 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")'
    fi
}

# 端口是否在监听
port_listening() {
    local p="$1"
    if has_cmd ss; then
        ss -H -ltn 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")' | grep -q .
    elif has_cmd netstat; then
        netstat -ltn 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")' | grep -q .
    else
        return 1
    fi
}

port_in_use() {
    local p="$1"
    # ss/netstat 输出列: State Recv-Q Send-Q Local-Addr:Port Peer-Addr:Port → 本地地址是第 4 列
    if has_cmd ss; then
        ss -H -ltnu 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")' | grep -q .
    elif has_cmd netstat; then
        netstat -ltnu 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")' | grep -q .
    else
        return 1
    fi
}

# ---------- 配置文件读写 ----------
save_install_info() {
    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
    {
        printf 'SOCKS_PORT=%q\n'   "$SOCKS_PORT"
        printf 'USE_AUTH=%q\n'     "$USE_AUTH"
        printf 'SOCKS_USER=%q\n'   "$SOCKS_USER"
        printf 'SOCKS_PASS=%q\n'   "$SOCKS_PASS"
        printf 'SERVER_IP=%q\n'    "$SERVER_IP"
        printf 'INTERFACE=%q\n'    "$INTERFACE"
        printf 'INSTALL_DATE=%q\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        # 不能叫 SCRIPT_VERSION：source 这个文件会把运行中的 $SCRIPT_VERSION 覆盖成
        # 「安装当时的版本」，导致菜单、升级比较、refresh 全部报错版本号
        printf 'MANAGER_VERSION=%q\n' "$SCRIPT_VERSION"
    } >"$INSTALL_INFO"
    chmod 600 "$INSTALL_INFO"
}

load_install_info() {
    [[ -f "$INSTALL_INFO" ]] || return 1
    # 这里 source 的是数据文件，绝不能让它污染脚本自身的运行状态。
    # 老版本记录里写的是 SCRIPT_VERSION=，同样要挡掉。
    local _saved_version="$SCRIPT_VERSION"
    # shellcheck disable=SC1090
    source "$INSTALL_INFO" 2>/dev/null
    SCRIPT_VERSION="$_saved_version"
    return 0
}

# 读安装记录里记录的版本（新键优先，兼容旧键）
info_version() {
    [[ -f "$INSTALL_INFO" ]] || return 0
    local v
    v=$(sed -n 's/^MANAGER_VERSION=//p' "$INSTALL_INFO" 2>/dev/null | tr -d "'\"" | head -n1)
    [[ -z "$v" ]] && v=$(sed -n 's/^SCRIPT_VERSION=//p' "$INSTALL_INFO" 2>/dev/null | tr -d "'\"" | head -n1)
    printf '%s' "$v"
}

load_limit_conf() {
    LIMIT_IFACE=""; LIMIT_PORT=""; LIMIT_DOWN=""; LIMIT_UP=""
    [[ -f "$LIMIT_CONF" ]] || return 1
    # shellcheck disable=SC1090
    source "$LIMIT_CONF" 2>/dev/null
    return 0
}

save_limit_conf() {
    mkdir -p "$CONFIG_DIR"
    {
        printf 'LIMIT_IFACE=%q\n' "$LIMIT_IFACE"
        printf 'LIMIT_PORT=%q\n'  "$LIMIT_PORT"
        printf 'LIMIT_DOWN=%q\n'  "$LIMIT_DOWN"
        printf 'LIMIT_UP=%q\n'    "$LIMIT_UP"
    } >"$LIMIT_CONF"
    chmod 600 "$LIMIT_CONF"
}

# ---------- 状态判断 ----------
dante_installed() {
    [[ -f "$S5_UNIT" ]] && return 0
    systemctl list-unit-files 2>/dev/null | grep -qE '^danted\.service'
}

dante_running() { systemctl is-active --quiet danted 2>/dev/null; }

# ============================================================
#  限速子系统  (tc HTB + ifb)
#
#  设计要点：
#   - 只匹配 SOCKS 端口，不碰整块网卡 —— 否则 SSH 会被一起限速，直接锁死自己。
#   - 出方向(服务器→客户端)：报文源端口 == SOCKS_PORT  → 视为"下载"
#   - 入方向(客户端→服务器)：报文目标端口 == SOCKS_PORT → 视为"上传"
#     入方向包用 ifb 中转后再整形（ingress 不能直接挂 htb）。
#   - 父类给 10Gbit，默认类不设限，只有命中端口的那一类被限。
# ============================================================

BIG_RATE="10000mbit"

# 把 10 / 10M / 800K / 10mbit 归一化成 tc 速率串；0 或空 = 不限
rate_norm() {
    local v num unit
    v=$(printf '%s' "$1" | tr -d ' ' | tr 'A-Z' 'a-z')
    [[ -z "$v" ]] && return 0
    [[ "$v" == "0" ]] && return 0
    case "$v" in
        *gbit) num="${v%%[a-z]*}"; unit="gbit" ;;
        *mbit) num="${v%%[a-z]*}"; unit="mbit" ;;
        *kbit) num="${v%%[a-z]*}"; unit="kbit" ;;
        *gb|*g) num="${v%%[a-z]*}"; unit="gbit" ;;
        *mb|*m) num="${v%%[a-z]*}"; unit="mbit" ;;
        *kb|*k) num="${v%%[a-z]*}"; unit="kbit" ;;
        *)     num="$v";            unit="mbit" ;;
    esac
    [[ "$num" =~ ^[0-9]+$ ]] || { log_error "无法识别的速率: $1"; return 1; }
    [[ "$num" -le 0 ]] && return 0
    printf '%s%s' "$num" "$unit"
}

shaping_clear() {
    local ifc="${1:-}"
    [[ -z "$ifc" ]] && ifc=$(get_iface)
    [[ -z "$ifc" ]] && return 0
    has_cmd tc || return 0
    tc qdisc del dev "$ifc" root    >/dev/null 2>&1
    tc qdisc del dev "$ifc" ingress >/dev/null 2>&1
    tc qdisc del dev "$IFB_DEV" root >/dev/null 2>&1
    ip link set "$IFB_DEV" down >/dev/null 2>&1
    return 0
}

# shaping_apply <iface> <port> <down_rate> <up_rate>
shaping_apply() {
    local ifc="$1" port="$2" down="$3" up="$4" rc=0

    has_cmd tc || { log_error "缺少 tc 命令（iproute2 未安装）"; return 1; }
    [[ -z "$ifc" ]] && { log_error "无法确定网卡接口"; return 1; }
    [[ -z "$port" ]] && { log_error "缺少端口参数"; return 1; }
    [[ -z "$down" && -z "$up" ]] && { shaping_clear "$ifc"; return 0; }

    shaping_clear "$ifc"

    # ---- 出方向 (服务器→客户端) = 下载限速 ----
    if [[ -n "$down" ]]; then
        tc qdisc add dev "$ifc" root handle 1: htb default 30 2>/dev/null || {
            log_error "创建出方向 htb 失败"; return 1; }
        tc class add dev "$ifc" parent 1:    classid 1:1  htb rate "$BIG_RATE" ceil "$BIG_RATE" 2>/dev/null
        tc class add dev "$ifc" parent 1:1  classid 1:10 htb rate "$down"     ceil "$down"     2>/dev/null
        tc class add dev "$ifc" parent 1:1  classid 1:30 htb rate "$BIG_RATE" ceil "$BIG_RATE" 2>/dev/null
        tc qdisc add dev "$ifc" parent 1:10 fq_codel 2>/dev/null
        tc qdisc add dev "$ifc" parent 1:30 fq_codel 2>/dev/null
        tc filter add dev "$ifc" parent 1: protocol ip prio 1 u32 \
            match ip sport "$port" 0xffff flowid 1:10 2>/dev/null
        [[ $? -ne 0 ]] && { log_warn "出方向过滤器添加失败"; rc=1; }
    fi

    # ---- 入方向 (客户端→服务器) = 上传限速，走 ifb ----
    if [[ -n "$up" ]]; then
        modprobe ifb >/dev/null 2>&1
        ip link show "$IFB_DEV" >/dev/null 2>&1 || ip link add "$IFB_DEV" type ifb 2>/dev/null
        if ! ip link show "$IFB_DEV" >/dev/null 2>&1; then
            log_error "ifb 设备创建失败（内核缺少 ifb 模块）"
            return 1
        fi
        ip link set "$IFB_DEV" up 2>/dev/null

        tc qdisc add dev "$ifc" handle ffff: ingress 2>/dev/null
        tc filter add dev "$ifc" parent ffff: protocol ip prio 1 u32 \
            match ip dport "$port" 0xffff \
            action mirred egress redirect dev "$IFB_DEV" 2>/dev/null
        [[ $? -ne 0 ]] && { log_warn "入方向重定向过滤器添加失败"; rc=1; }

        tc qdisc add dev "$IFB_DEV" root handle 2: htb default 10 2>/dev/null
        tc class add dev "$IFB_DEV" parent 2:   classid 2:1  htb rate "$BIG_RATE" ceil "$BIG_RATE" 2>/dev/null
        tc class add dev "$IFB_DEV" parent 2:1 classid 2:10 htb rate "$up"       ceil "$up"        2>/dev/null
        tc qdisc add dev "$IFB_DEV" parent 2:10 fq_codel 2>/dev/null
    fi

    return $rc
}

# 限速持久化：写一个自包含的 shim + systemd oneshot 单元
# 不依赖本脚本被复制到哪里，curl|bash 场景同样有效
SHAPING_HELPER="/usr/local/sbin/socks5-shaping"

write_shaping_helper() {
    cat >"$SHAPING_HELPER" <<EOS
#!/bin/sh
# 由 socks5 管理脚本 v$SCRIPT_VERSION 生成，请勿手改（重新设置限速会覆盖）
CONF="$LIMIT_CONF"
IFB="$IFB_DEV"
BIG="10000mbit"

[ -f "\$CONF" ] || exit 0
. "\$CONF"
iface=\${LIMIT_IFACE:-}
port=\${LIMIT_PORT:-}
down=\${LIMIT_DOWN:-}
up=\${LIMIT_UP:-}
[ -z "\$iface" ] && exit 0
command -v tc >/dev/null 2>&1 || exit 0

clear_all() {
    tc qdisc del dev "\$iface" root     2>/dev/null
    tc qdisc del dev "\$iface" ingress  2>/dev/null
    tc qdisc del dev "\$IFB"    root     2>/dev/null
    ip link set "\$IFB" down 2>/dev/null
}

case "\$1" in
    clear) clear_all; exit 0 ;;
esac

[ -z "\$down\$up" ] && { clear_all; exit 0; }
clear_all

if [ -n "\$down" ]; then
    tc qdisc add dev "\$iface" root handle 1: htb default 30 || exit 1
    tc class add dev "\$iface" parent 1:   classid 1:1  htb rate "\$BIG" ceil "\$BIG" 2>/dev/null
    tc class add dev "\$iface" parent 1:1 classid 1:10 htb rate "\$down" ceil "\$down" 2>/dev/null
    tc class add dev "\$iface" parent 1:1 classid 1:30 htb rate "\$BIG" ceil "\$BIG" 2>/dev/null
    tc qdisc add dev "\$iface" parent 1:10 fq_codel 2>/dev/null
    tc qdisc add dev "\$iface" parent 1:30 fq_codel 2>/dev/null
    tc filter add dev "\$iface" parent 1: protocol ip prio 1 u32 \\
        match ip sport "\$port" 0xffff flowid 1:10 2>/dev/null
fi

if [ -n "\$up" ]; then
    modprobe ifb >/dev/null 2>&1
    ip link show "\$IFB" >/dev/null 2>&1 || ip link add "\$IFB" type ifb 2>/dev/null
    ip link set "\$IFB" up 2>/dev/null
    tc qdisc add dev "\$iface" handle ffff: ingress 2>/dev/null
    tc filter add dev "\$iface" parent ffff: protocol ip prio 1 u32 \\
        match ip dport "\$port" 0xffff \\
        action mirred egress redirect dev "\$IFB" 2>/dev/null
    tc qdisc add dev "\$IFB" root handle 2: htb default 10 2>/dev/null
    tc class add dev "\$IFB" parent 2:   classid 2:1  htb rate "\$BIG" ceil "\$BIG" 2>/dev/null
    tc class add dev "\$IFB" parent 2:1 classid 2:10 htb rate "\$up" ceil "\$up" 2>/dev/null
    tc qdisc add dev "\$IFB" parent 2:10 fq_codel 2>/dev/null
fi

exit 0
EOS
    chmod 0755 "$SHAPING_HELPER"
}

write_shaping_unit() {
    write_shaping_helper
    cat >"$SHAPING_UNIT" <<EOF
[Unit]
Description=SOCKS5 port rate limit (tc HTB shaping)
After=network-online.target danted.service
Wants=network-online.target
PartOf=danted.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SHAPING_HELPER apply
ExecStop=$SHAPING_HELPER clear
StandardOutput=journal

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

# 把管理命令装到 PATH，方便后续敲 socks5
# 注意：用 bash <(curl ...) 方式运行时 $0 是 /dev/fd/63 —— 那是个管道，
# 不是普通文件。此时既不能 install 复制（bash 还在从它读，复制只能拿到半截），
# 也不能靠 $0 判断版本，唯一可靠做法是重新拉一份完整脚本。
install_self() {
    if [[ -f "$0" ]] && [[ "$(readlink -f "$0" 2>/dev/null)" == "$(readlink -f "$SELF_PATH" 2>/dev/null)" ]]; then
        return 0
    fi

    local got=""

    if [[ -f "$0" && -r "$0" ]]; then
        mkdir -p "$(dirname "$SELF_PATH")" 2>/dev/null
        install -m 0755 "$0" "$SELF_PATH" 2>/dev/null && got="local"
    fi

    if [[ -z "$got" ]]; then
        local tmp="" dv=""
        tmp=$(mktemp /tmp/socks5.XXXXXX 2>/dev/null) || return 0
        # 走 fetch_latest（API 优先），不要直接用 SELF_URL：
        # raw.githubusercontent 的缓存可能滞后很久，某些网络环境下
        # 甚至会一直返回旧内容，直接拿它装会把旧版固化成常驻命令。
        if fetch_latest "$tmp"; then
            dv=$(ver_of "$tmp")
            if [[ -n "$dv" && "$dv" != "$SCRIPT_VERSION" ]]; then
                log_warn "下载到的是 v$dv，当前运行 v$SCRIPT_VERSION（缓存滞后，稍后用 socks5 upgrade 再拉一次）"
            fi
            install -m 0755 "$tmp" "$SELF_PATH" 2>/dev/null && got="download"
        fi
        rm -f "$tmp" 2>/dev/null
    fi

    if [[ -n "$got" ]]; then
        log_info "管理命令已安装: $SELF_PATH"
    else
        log_warn "未能安装 $SELF_PATH；下次可直接运行: bash <(curl -fsSL $SELF_URL)"
    fi
    return 0
}

# ---------- 版本比较与升级 ----------
# 从任意脚本文件里取 SCRIPT_VERSION
ver_of() {
    sed -n 's/^SCRIPT_VERSION="\(.*\)"/\1/p' "$1" 2>/dev/null | head -n1
}

# $1 是否比 $2 新（只处理点分数字，够用）
ver_newer() {
    local a="${1#v}" b="${2#v}"
    [[ -z "$a" || -z "$b" ]] && return 1
    [[ "$a" == "$b" ]] && return 1
    local IFS='.'
    local -a A B
    # shellcheck disable=SC2206
    A=($a)
    B=($b)
    local i n x y
    n=${#A[@]}
    [[ ${#B[@]} -gt $n ]] && n=${#B[@]}
    for ((i = 0; i < n; i++)); do
        x="${A[i]:-0}"; y="${B[i]:-0}"
        [[ "$x" =~ ^[0-9]+$ ]] || x=0
        [[ "$y" =~ ^[0-9]+$ ]] || y=0
        ((10#$x > 10#$y)) && return 0
        ((10#$x < 10#$y)) && return 1
    done
    return 1
}

# 取最新脚本到 $1，并校验它确实是本项目的完整脚本
fetch_latest() {
    local out="$1"
    has_cmd curl || { log_error "缺少 curl"; return 1; }

    # 1) API raw：不受 Fastly 缓存影响，但匿名有频率限制
    if curl -fsSL --max-time 25 -H 'Accept: application/vnd.github.raw' \
        "$SELF_API_URL" -o "$out" 2>/dev/null && [[ -s "$out" ]]; then
        :
    # 2) 退回 raw（可能拿到缓存里的旧版，由调用方比对版本）
    elif curl -fsSL --max-time 25 -H 'Cache-Control: no-cache' \
        "$SELF_URL" -o "$out" 2>/dev/null && [[ -s "$out" ]]; then
        :
    else
        return 1
    fi

    head -n1 "$out" 2>/dev/null | grep -q '^#!.*bash' || return 1
    grep -q 'SCRIPT_VERSION=' "$out" 2>/dev/null || return 1
    return 0
}

# 升级脚本本身；成功后用新脚本重建服务配置（旧进程里的函数可能是旧格式）
do_upgrade() {
    local force="${1:-}"
    echo
    log_step "检查更新"

    local cur="$SCRIPT_VERSION" inst="" base="" tmp=""
    # 基准取「已安装命令的版本」——那才是下次运行实际会用的东西。
    # 同一进程里刚升级完 $SCRIPT_VERSION 不会变，只能靠文件判断。
    [[ -f "$SELF_PATH" ]] && inst=$(ver_of "$SELF_PATH")
    base="$cur"
    ver_newer "$inst" "$cur" && base="$inst"

    tmp=$(mktemp /tmp/socks5.up.XXXXXX 2>/dev/null) || { log_error "无法创建临时文件"; return 1; }

    if ! fetch_latest "$tmp"; then
        rm -f "$tmp"
        log_error "拉取最新版本失败（网络不通或被墙），可手动替换："
        echo "  curl -fsSL -H 'Accept: application/vnd.github.raw' '$SELF_API_URL' -o $SELF_PATH"
        return 1
    fi

    local new c
    new=$(ver_of "$tmp")
    log_info "当前运行: v$cur"
    [[ -n "$inst" && "$inst" != "$cur" ]] && log_warn "已安装命令是 v$inst，与正在运行的 v$cur 不一致"
    log_info "远端版本: v$new（比较基准 v$base）"

    if [[ "$new" == "$base" ]]; then
        log_success "已是最新版本 v$base"
        rm -f "$tmp"
        return 0
    fi

    if ver_newer "$new" "$base"; then
        [[ "$force" == "--force" ]] && c=y || {
            echo -n "升级到 v$new？[y/N]: "
            read -r c
        }
    else
        log_warn "远端 v$new 不比 v$base 新（通常是 CDN 缓存滞后）"
        [[ "$force" == "--force" ]] && c=y || {
            echo -n "仍要覆盖安装 v$new？[y/N]: "
            read -r c
        }
    fi
    [[ "${c,,}" != "y" ]] && { rm -f "$tmp"; log_info "已取消"; return 0; }

    if [[ -f "$SELF_PATH" ]]; then
        cp -f "$SELF_PATH" "${SELF_PATH}.bak" 2>/dev/null && log_info "旧版已备份: ${SELF_PATH}.bak"
    fi
    mkdir -p "$(dirname "$SELF_PATH")" 2>/dev/null
    if ! install -m 0755 "$tmp" "$SELF_PATH" 2>/dev/null; then
        rm -f "$tmp"
        log_error "写入 $SELF_PATH 失败"
        return 1
    fi
    rm -f "$tmp"

    # 装完必须回读校验：写失败、写到别处、文件被截断，都在这里暴露
    local iv
    iv=$(ver_of "$SELF_PATH")
    if [[ "$iv" != "$new" ]]; then
        log_error "安装后校验失败：$SELF_PATH 现在是 v${iv:-未知}，期望 v$new"
        log_error "可能原因：磁盘满、权限、或下载内容不完整"
        return 1
    fi

    log_success "脚本已升级: v$cur → v$new（已回读校验）"
    log_usage "upgrade $cur -> $new"

    # 关键：换脚本不等于换配置。新版本的 danted.conf / systemd 单元生成逻辑
    # 可能修过，必须让新脚本自己重写一遍，不能拿当前进程里的旧函数去写。
    if [[ -f "$INSTALL_INFO" ]]; then
        echo
        echo -n "同时用新版本重建服务配置（danted.conf + systemd 单元）并重启？[Y/n]: "
        read -r c
        if [[ "${c,,}" != "n" ]]; then
            exec bash "$SELF_PATH" refresh
        fi
    fi
    echo
    log_info "已装新版本，重新执行 socks5 即可使用"
    return 0
}

# 按安装记录重建 danted.conf 与 systemd 单元，然后重启
do_refresh() {
    if ! load_install_info; then
        log_error "没有安装记录（$INSTALL_INFO），无法重建配置；请执行安装"
        return 1
    fi
    SOCKS_PORT="${SOCKS_PORT:-1080}"
    INTERFACE="${INTERFACE:-$(resolve_iface)}"
    SERVER_IP="${SERVER_IP:-$(get_public_ip)}"
    [[ -x "$DANTE_BIN" ]] || DANTE_BIN=$(command -v danted 2>/dev/null || echo "$DANTE_BIN")

    log_step "重建 danted.conf（脚本 v$SCRIPT_VERSION）"
    write_danted_conf

    log_step "校验配置"
    local vlog
    if ! vlog=$("$DANTE_BIN" -V -f "$DANTE_CONF" 2>&1); then
        log_error "重建后的配置校验失败，已保留备份，未重启服务："
        printf '%s\n' "$vlog"
        return 1
    fi

    log_step "重建 systemd 单元"
    write_systemd_unit

    log_step "重启服务"
    stop_dante_clean
    systemctl enable danted >/dev/null 2>&1
    if ! start_dante; then
        dump_dante_failure
        return 1
    fi

    if [[ -n "$LIMIT_DOWN$LIMIT_UP" ]]; then
        write_shaping_helper
        systemctl enable socks5-shaping >/dev/null 2>&1
        systemctl restart socks5-shaping >/dev/null 2>&1
        log_info "限速规则已重新应用: $(limit_status_text)"
    fi

    save_install_info
    log_success "已按 v$SCRIPT_VERSION 重建配置并重启，端口 $SOCKS_PORT"
    log_usage "refresh by v$SCRIPT_VERSION"
    return 0
}

limit_apply_from_conf() {
    load_limit_conf || return 0
    [[ -z "$LIMIT_IFACE" ]] && return 0
    # 接口名可能因重装网卡变化，接口不存在则重新探测
    ip link show "$LIMIT_IFACE" >/dev/null 2>&1 || LIMIT_IFACE=$(get_iface)
    [[ -z "$LIMIT_DOWN" && -z "$LIMIT_UP" ]] && { shaping_clear "$LIMIT_IFACE"; return 0; }
    shaping_apply "$LIMIT_IFACE" "$LIMIT_PORT" "$LIMIT_DOWN" "$LIMIT_UP"
}

# ============================================================
#  Dante 侧配置
# ============================================================
ensure_pam_service() {
    [[ -f /etc/pam.d/danted ]] && return 0
    mkdir -p /etc/pam.d 2>/dev/null
    if {
        cat >/etc/pam.d/danted <<'EOF'
# Dante SOCKS5 认证栈（脚本生成）
auth     required   pam_unix.so
account  required   pam_unix.so
EOF
    } 2>/dev/null; then
        log_info "已创建 /etc/pam.d/danted"
    else
        log_warn "无法创建 /etc/pam.d/danted，用户名密码认证可能失败"
    fi
}

create_system_user() {
    if [[ "$USE_AUTH" != true ]]; then
        log_info "无认证模式，跳过用户创建"
        return 0
    fi
    log_info "配置认证用户: $SOCKS_USER"

    if id "$SOCKS_USER" >/dev/null 2>&1; then
        log_warn "用户 $SOCKS_USER 已存在，直接重置密码"
    else
        local shell_bin=/usr/sbin/nologin err=""
        [[ -x /sbin/nologin ]] && shell_bin=/sbin/nologin
        # 先按系统默认策略建；被拒则用 --badname 跳过用户名正则
        # （大写开头、数字开头这类名字 useradd 默认不收，但内核和 PAM 本身无所谓）
        if ! err=$(useradd -r -M -s "$shell_bin" "$SOCKS_USER" 2>&1); then
            log_warn "useradd 默认策略拒绝该用户名，改用 --badname 重试"
            if ! err=$(useradd -r -M -s "$shell_bin" --badname "$SOCKS_USER" 2>&1); then
                if ! err=$(useradd -M -s "$shell_bin" --badname "$SOCKS_USER" 2>&1); then
                    log_error "系统拒绝创建用户 [$SOCKS_USER]：$err"
                    log_error "dante 的用户名认证依赖真实系统账号，换一个用户名再试"
                    return 1
                fi
            fi
        fi
        log_info "用户 $SOCKS_USER 已创建"
    fi

    # chpasswd 失败时用 openssl 直写 shadow 哈希
    if ! printf '%s:%s\n' "$SOCKS_USER" "$SOCKS_PASS" | chpasswd 2>/dev/null; then
        # 部分系统的 chpasswd 会经 pam_pwquality 拒绝简单口令，直写哈希绕过
        local h=""
        if has_cmd openssl; then
            h=$(printf '%s' "$SOCKS_PASS" | openssl passwd -6 -stdin 2>/dev/null)
        fi
        if [[ -n "$h" ]]; then
            usermod -p "$h" "$SOCKS_USER" || { log_error "写入密码失败"; return 1; }
            log_info "密码已写入（绕过 PAM 复杂度校验）"
        else
            log_error "设置密码失败：chpasswd 与 openssl 均不可用"
            return 1
        fi
    else
        log_info "用户密码已设置"
    fi

    # 避免账户因密码过期被 PAM 拒绝
    chage -E -1 -M 99999 "$SOCKS_USER" 2>/dev/null

    ensure_pam_service
    return 0
}

write_danted_conf() {
    log_step "写入 Dante 配置"

    if [[ -f "$DANTE_CONF" ]]; then
        cp "$DANTE_CONF" "${DANTE_CONF}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
        log_info "原配置已备份"
    fi

    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"

    local method_name="none"
    [[ "$USE_AUTH" == true ]] && method_name="username"

    cat >"$DANTE_CONF" <<EOF
# Dante SOCKS5 配置 — 由 socks5 管理脚本 v$SCRIPT_VERSION 生成
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

logoutput: $LOG_FILE
debug: 0

# 监听所有网卡的 SOCKS 端口
internal: 0.0.0.0 port = $SOCKS_PORT
# 出口网卡
external: $INTERFACE

# 认证方式
socksmethod: $method_name
clientmethod: none

# 进程权限
user.privileged: root
user.unprivileged: nobody

# 超时沿用 dante 默认值：连接 30 秒，空闲不超时

# 客户端接入规则
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}

# SOCKS 转发规则
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
    socksmethod: $method_name
}
EOF
    log_info "配置已写入 $DANTE_CONF"
}

write_systemd_unit() {
    # 关键：danted 不加 -D 时在前台运行、不 fork。
    # 所以必须用 Type=simple 直接托管前台进程；
    # 用 Type=forking 会等一个永远不出现的父进程退出（90 秒超时后强杀）。
    # 同理不要写 PIDFile：pid 文件只有传 -p 才会生成。
    cat >"$S5_UNIT" <<EOF
[Unit]
Description=Dante SOCKS5 Server
Documentation=man:danted(8)
After=network-online.target
Wants=network-online.target
# 进程如果被外部杀掉，不要因为"重启太频繁"而彻底放弃
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$DANTE_BIN -f $DANTE_CONF
ExecReload=/bin/kill -HUP \$MAINPID
# danted 会派生多个子进程（mother/negotiate/request/io），
# 必须让 systemd 管住整个 cgroup，否则停止后子进程继续占着端口
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=15
# always 而不是 on-failure：进程被 SIGKILL（云安全agent/OOM）时
# ExitCode 可能仍为 0，on-failure 不会重启，服务就永久躺着
Restart=always
RestartSec=3
# 用 65535 而不是 1048576：超过内核 fs.nr_open 时 systemd 只能钳位，
# 某些内核上会连带启动失败，代理服务这个量级 65535 足够
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    log_info "systemd 单元已写入（Type=simple, Restart=always）"
}

write_logrotate() {
    cat >"$LOGROTATE_FILE" <<EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0640 root root
}
EOF
}

# ---------- 防火墙 ----------
open_port() {
    local p="$1"
    command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | grep -qi inactive && {
        ufw allow "${p}/tcp" >/dev/null 2>&1
        ufw allow "${p}/udp" >/dev/null 2>&1
        log_info "UFW: 已放行 ${p}/tcp+udp"
        return 0
    }
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
        firewall-cmd --permanent --add-port="${p}/udp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log_info "firewalld: 已放行 ${p}/tcp+udp"
        return 0
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p udp --dport "$p" -j ACCEPT
        if [[ "$OS" == "rhel" ]]; then
            { service iptables save >/dev/null 2>&1 || { iptables-save >/etc/sysconfig/iptables; }; } 2>/dev/null
        else
            mkdir -p /etc/iptables 2>/dev/null
            { netfilter-persistent save >/dev/null 2>&1 || { iptables-save >/etc/iptables/rules.v4; }; } 2>/dev/null
        fi
        log_info "iptables: 已放行 ${p}/tcp+udp"
        return 0
    fi
    log_warn "未检测到防火墙工具，请自行放行端口 $p"
}

close_port() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${p}/tcp" >/dev/null 2>&1
        ufw delete allow "${p}/udp" >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1
        firewall-cmd --permanent --remove-port="${p}/udp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        local n=0
        while [[ $n -lt 20 ]] && iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || break
            n=$((n + 1))
        done
        n=0
        while [[ $n -lt 20 ]] && iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || break
            n=$((n + 1))
        done
    fi
    log_info "已清理端口 $p 的放行规则"
}

# ---------- 安装依赖 ----------
install_dependencies() {
    log_step "安装依赖"
    if [[ "$OS" == "rhel" ]]; then
        $PM install -y epel-release >/dev/null 2>&1 || true
        pkg_install dante-server iproute iproute-tc curl logrotate \
            || die "依赖安装失败（dante-server 可能需要 EPEL）"
    else
        $PM update -y >/dev/null 2>&1 || log_warn "apt update 有警告，继续"
        pkg_install dante-server iproute2 curl logrotate || die "依赖安装失败"
    fi

    # danted 可执行文件路径兜底
    if ! [[ -x "$DANTE_BIN" ]]; then
        local real
        real=$(command -v danted 2>/dev/null)
        [[ -n "$real" ]] && DANTE_BIN="$real" && log_warn "danted 路径已修正为 $DANTE_BIN"
    fi
    [[ -x "$DANTE_BIN" ]] || die "找不到 danted 可执行文件"
    has_cmd tc || log_warn "tc 不可用，限速功能将不可用"
    log_info "依赖就绪"
}

# ---------- 交互输入 ----------
ask_port() {
    local def="${1:-1080}" input
    while true; do
        read -r -p "SOCKS5 端口 [默认 ${def}]: " input
        input="${input:-$def}"
        if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 || "$input" -gt 65535 ]]; then
            log_error "端口必须是 1-65535 的整数"
            continue
        fi
        if port_in_use "$input"; then
            # 若占用者就是自己（重装同端口），允许
            if [[ "$input" == "${SOCKS_PORT:-}" ]] && dante_running; then
                SOCKS_PORT="$input"; return 0
            fi
            log_error "端口 $input 已被占用"
            port_listeners "$input" | head -n1
            continue
        fi
        SOCKS_PORT="$input"
        return 0
    done
}

# ---------- 凭据规则 ----------
# 用户名只挡三类真正会坏事的字符：
#   :   —— 会破坏 chpasswd 的 "user:pass" 行格式
#   空格 —— 会破坏命令行与配置引用
#   - 开头 —— 会被当成命令选项
# 大小写、数字开头、点、@、# 等全部放行；真正的上限来自系统的 useradd
valid_user_name() {
    local v="$1"
    [[ -z "$v" ]] && return 1
    [[ ${#v} -gt 32 ]] && return 1
    [[ "$v" == *:* ]] && return 1
    [[ "$v" == *[[:space:]]* ]] && return 1
    [[ "$v" == -* ]] && return 1
    return 0
}

# 密码除长度外不设限
valid_password() {
    [[ ${#1} -ge 1 && ${#1} -le 64 ]]
}

# 生成客户端命令。凭据走 --proxy-user 传，绕开 URL 解析，
# 所以密码里带 @ : / # ? % 这些字符也不用手动转义
curl_hint() {
    local host="$1" port="$2"
    if [[ "$USE_AUTH" == true ]]; then
        printf 'curl --socks5-hostname %s:%s --proxy-user %s https://api.ipify.org' \
            "$host" "$port" "$(printf '%q' "${SOCKS_USER}:${SOCKS_PASS}")"
    else
        printf 'curl --socks5-hostname %s:%s https://api.ipify.org' "$host" "$port"
    fi
}

ask_auth() {
    local m u p
    echo
    echo -e "${YELLOW}认证方式：${NC}"
    echo "  1) 用户名密码认证  (推荐)"
    echo "  2) 无认证          (仅限内网 / 临时测试)"
    read -r -p "请选择 [默认 1]: " m
    m="${m:-1}"

    if [[ "$m" == "2" ]]; then
        echo -n "确认使用无认证模式？任何人都能拿它当代理 [y/N]: "
        read -r c
        if [[ "${c,,}" != "y" ]]; then ask_auth; return; fi
        USE_AUTH=false; SOCKS_USER=""; SOCKS_PASS=""
        log_warn "已选择无认证模式"
        return 0
    fi

    USE_AUTH=true

    while true; do
        read -r -p "用户名 [默认 socksuser，大小写随意]: " u
        SOCKS_USER="${u:-socksuser}"
        valid_user_name "$SOCKS_USER" && break
        log_error "用户名被拒：不能为空、不能超过 32 位、不能含冒号或空格、不能以 - 开头"
    done

    while true; do
        IFS= read -r -s -p "密码 [留空自动生成 16 位，字符不限]: " p
        echo
        if [[ -z "$p" ]]; then
            p=$(gen_pass)
            log_info "已自动生成密码: $p"
        fi
        valid_password "$p" && { SOCKS_PASS="$p"; break; }
        log_error "密码最长 64 位"
    done
    return 0
}

# ---------- 连接测试 ----------
detect_iface() {
    INTERFACE=$(get_iface)
    [[ -z "$INTERFACE" ]] && die "无法探测出口网卡，请手动指定"
    log_info "出口网卡: $INTERFACE"
}

# 只测 TCP 能不能建立，不做协议握手。用于判断「外部能否连到这个端口」
# —— 安全组/上游防火墙拦截的特征就是：本机通，公网不通
tcp_probe() {
    local h="$1" p="$2"
    [[ -z "$h" || -z "$p" ]] && return 1
    if has_cmd timeout; then
        timeout 6 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null
    else
        (exec 3<>/dev/tcp/"$h"/"$p") 2>/dev/null
    fi
}

test_proxy() {
    local rc=0
    port_listening "$SOCKS_PORT" || { log_error "端口 $SOCKS_PORT 未监听"; return 1; }
    log_success "端口 $SOCKS_PORT 正在监听"

    has_cmd curl || { log_info "curl 未安装，跳过连通性测试"; return 0; }

    if [[ "$USE_AUTH" == true ]]; then
        # 凭据用 --proxy-user 传，避免密码里的 @ : / 等字符被当成 URL 的一部分
        timeout 12 curl -s --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
            --proxy-user "${SOCKS_USER}:${SOCKS_PASS}" \
            http://api.ipify.org >/dev/null 2>&1
        rc=$?
    else
        timeout 12 curl -s --socks5-hostname "127.0.0.1:${SOCKS_PORT}" \
            http://api.ipify.org >/dev/null 2>&1
        rc=$?
    fi

    case $rc in
        0) log_success "本机经代理出网正常" ;;
        5|6) log_error "代理握手/认证失败（rc=$rc），检查用户名密码与 PAM" ;;
        7)  log_error "本机连不上端口（rc=7），danted 没在监听或已崩" ;;
        28) log_error "代理出网超时（rc=28）：本机能进代理，但代理连不上目标" ;;
        *)  log_warn "本机经代理出网未通过（rc=$rc）" ;;
    esac

    # 关键的第二跳：从公网 IP 再连一次这个端口。
    # 只测 127.0.0.1 无法发现云安全组/上游防火墙拦截。
    if [[ -n "$SERVER_IP" && "$SERVER_IP" != "0.0.0.0" && "$SERVER_IP" != "127.0.0.1" ]]; then
        if tcp_probe "$SERVER_IP" "$SOCKS_PORT"; then
            log_success "公网 ${SERVER_IP}:${SOCKS_PORT} 可建立 TCP 连接"
        else
            log_error "公网 ${SERVER_IP}:${SOCKS_PORT} 连不上"
            echo -e "  ${YELLOW}本机通、公网不通 = 云安全组或上游防火墙拦了，脚本管不到这一段${NC}"
            echo "  控制台放行: 入方向 TCP ${SOCKS_PORT}"
            echo "  阿里云/腾讯云/华为云 → 安全组；其他 → 服务商面板防火墙"
        fi
    fi
    return 0
}

# ============================================================
#  业务：安装
# ============================================================
do_install() {
    echo
    local old_port="" c
    if dante_installed; then
        load_install_info && old_port="$SOCKS_PORT"
        log_warn "检测到已安装（端口 ${old_port:-未知}），重新配置会覆盖现有设置"
        echo -n "继续？[y/N]: "
        read -r c
        [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }
        # 旧限速规则先撤掉，端口变了以后规则会错位
        systemctl disable --now socks5-shaping >/dev/null 2>&1
        shaping_clear "$(get_iface)"
    fi

    detect_os
    install_dependencies
    detect_iface
    SERVER_IP=$(get_public_ip)
    log_info "公网 IP: $SERVER_IP"

    echo
    log_step "配置参数"
    ask_port "${SOCKS_PORT:-1080}"
    ask_auth

    create_system_user
    write_danted_conf

    log_step "校验 Dante 配置"
    # 注意：-V 才是"校验配置并退出"，-v 是"打印版本号"（永远返回 0）
    local vlog
    if ! vlog=$("$DANTE_BIN" -V -f "$DANTE_CONF" 2>&1); then
        log_error "配置校验失败，danted 输出："
        printf '%s\n' "$vlog"
        return 1
    fi
    [[ -n "$vlog" ]] && printf '%s\n' "$vlog"
    log_success "配置校验通过"

    write_systemd_unit
    write_logrotate
    open_port "$SOCKS_PORT"
    if [[ -n "$old_port" && "$old_port" != "$SOCKS_PORT" ]]; then
        close_port "$old_port"
        log_info "已清理旧端口 $old_port 的放行规则"
    fi
    install_self
    write_shaping_unit
    save_install_info

    log_step "启动服务"
    stop_dante_clean
    systemctl enable danted >/dev/null 2>&1

    if ! start_dante; then
        dump_dante_failure
        return 1
    fi

    # 有旧限速配置则恢复
    load_limit_conf && [[ -n "$LIMIT_DOWN$LIMIT_UP" ]] && {
        LIMIT_PORT="$SOCKS_PORT"; LIMIT_IFACE="$INTERFACE"; save_limit_conf
        systemctl enable socks5-shaping >/dev/null 2>&1
        systemctl restart socks5-shaping >/dev/null 2>&1
        log_info "已恢复原有端口限速设置"
    }

    test_proxy
    show_install_complete
    log_usage "installed port=$SOCKS_PORT auth=$USE_AUTH"
}

show_install_complete() {
    echo
    hr
    log_success "SOCKS5 安装完成"
    hr
    echo -e "服务器:   ${GREEN}${SERVER_IP}${NC}"
    echo -e "端口:     ${GREEN}${SOCKS_PORT}${NC}"
    echo -e "协议:     ${GREEN}SOCKS5${NC}"
    if [[ "$USE_AUTH" == true ]]; then
        echo -e "认证:     ${GREEN}用户名密码${NC}"
        echo -e "用户名:   ${GREEN}${SOCKS_USER}${NC}"
        echo -e "密码:     ${GREEN}${SOCKS_PASS}${NC}"
        echo -e "测试:     ${YELLOW}$(curl_hint "$SERVER_IP" "$SOCKS_PORT")${NC}"
    else
        echo -e "认证:     ${RED}无认证${NC}"
        echo -e "测试:     ${YELLOW}$(curl_hint "$SERVER_IP" "$SOCKS_PORT")${NC}"
        echo -e "${RED}注意: 无认证状态下任何知道 IP:端口 的人都能用你的带宽${NC}"
    fi
    echo
    echo -e "日常管理: ${YELLOW}socks5${NC}   （或 bash $0）"
    echo -e "服务控制: ${YELLOW}systemctl {start|stop|restart|status} danted${NC}"
    echo -e "实时日志: ${YELLOW}tail -f $LOG_FILE${NC}"
    hr
}

# ============================================================
#  业务：修改
# ============================================================
do_modify() {
    if ! dante_installed; then log_error "尚未安装，请先执行安装"; return 1; fi
    load_install_info || log_warn "安装信息缺失，部分选项可能不可用"
    SOCKS_PORT="${SOCKS_PORT:-1080}"
    INTERFACE="${INTERFACE:-$(resolve_iface)}"
    SERVER_IP="${SERVER_IP:-$(get_public_ip)}"

    echo
    echo -e "${CYAN}当前配置${NC}"
    hr
    echo "  端口:     $SOCKS_PORT"
    echo "  认证:     $([[ "$USE_AUTH" == true ]] && echo "用户名密码 (${SOCKS_USER})" || echo "无认证")"
    load_limit_conf
    if [[ -n "$LIMIT_DOWN$LIMIT_UP" ]]; then
        echo "  限速:     下载 ${LIMIT_DOWN:-不限} / 上传 ${LIMIT_UP:-不限}"
    else
        echo "  限速:     未启用"
    fi
    hr
    echo "  1) 修改端口"
    echo "  2) 修改用户名密码"
    echo "  3) 切换认证模式（启用/关闭认证）"
    echo "  4) 完全重新配置"
    echo "  5) 用当前设置重写 danted.conf 并重启"
    echo "  0) 返回"
    echo
    local ch c
    read -r -p "请选择: " ch

    case "$ch" in
        1)
            local old="$SOCKS_PORT" newp
            ask_port "$old"
            newp="$SOCKS_PORT"
            if [[ "$newp" == "$old" ]]; then log_info "端口未变化"; return 0; fi
            if retune_port "$old" "$newp"; then
                log_success "端口已从 $old 改为 $SOCKS_PORT"
            else
                log_error "端口配置已改，但服务未正常启动；查看: journalctl -u danted -n 30"
            fi
            ;;
        2)
            ask_auth
            create_system_user || { log_error "认证用户创建失败，配置未改动"; return 1; }
            write_danted_conf
            save_install_info
            if restart_dante; then log_success "认证信息已更新"; fi
            ;;
        3)
            if [[ "$USE_AUTH" == true ]]; then
                echo -n "确认关闭认证？[y/N]: "; read -r c
                [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }
                use_auth_off_note "$SOCKS_USER"
                USE_AUTH=false; SOCKS_USER=""; SOCKS_PASS=""
            else
                echo -n "确认开启用户名密码认证？[y/N]: "; read -r c
                [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }
                ask_auth
                create_system_user || { log_error "认证用户创建失败，认证模式未改动"; return 1; }
            fi
            write_danted_conf
            save_install_info
            if restart_dante; then log_success "认证模式已切换"; fi
            ;;
        4)
            local old4="$SOCKS_PORT"
            ask_port "$old4"
            ask_auth
            create_system_user || { log_error "认证用户创建失败，配置未改动"; return 1; }
            if [[ "$SOCKS_PORT" != "$old4" ]]; then
                retune_port "$old4" "$SOCKS_PORT" \
                    && log_success "配置已更新（端口 $SOCKS_PORT）" \
                    || log_error "配置已写入，但服务未正常启动"
            else
                write_danted_conf
                open_port "$SOCKS_PORT"
                save_install_info
                restart_dante && log_success "配置已更新（端口 $SOCKS_PORT）"
            fi
            ;;
        5)
            write_danted_conf
            restart_dante && log_success "danted.conf 已按当前设置重写"
            ;;
        0) return 0 ;;
        *) log_error "无效选择" ;;
    esac
    log_usage "config modified ($ch)"
}

# 关闭认证后提醒：认证用户还留在系统里
use_auth_off_note() {
    local u="$1"
    [[ -n "$u" ]] && id "$u" >/dev/null 2>&1 \
        && log_warn "系统用户 $u 仍保留在 /etc/passwd，需要删除请用「卸载」选项"
}

# 端口变更统一处理：重写配置 → 开新端口 → 关旧端口 → 同步限速 → 重启
retune_port() {
    local old="$1" new="$2"
    write_danted_conf_with "$new"
    SOCKS_PORT="$new"
    open_port "$new"
    close_port "$old"
    save_install_info

    load_limit_conf
    if [[ -n "$LIMIT_DOWN$LIMIT_UP" ]]; then
        LIMIT_PORT="$new"
        LIMIT_IFACE="${LIMIT_IFACE:-$(resolve_iface)}"
        save_limit_conf
        write_shaping_helper
        systemctl try-restart socks5-shaping >/dev/null 2>&1
        log_info "限速规则已跟随端口更新"
    fi
    restart_dante
}

# 用指定端口写配置（供改端口时使用，不改全局变量语义）
write_danted_conf_with() {
    local np="$1" old="$SOCKS_PORT"
    SOCKS_PORT="$np"
    write_danted_conf
    SOCKS_PORT="$old"
}

# 彻底停掉 danted
# dante 会派生一组子进程；历史上用 KillMode=process 时停不干净，
# 残留进程继续占着监听端口，下一次启动必然失败。
stop_dante_clean() {
    systemctl stop danted >/dev/null 2>&1
    systemctl reset-failed danted >/dev/null 2>&1
    if has_cmd pgrep && pgrep -x danted >/dev/null 2>&1; then
        log_warn "清理残留 danted 进程"
        has_cmd pkill && pkill -x danted >/dev/null 2>&1
        sleep 1
        if pgrep -x danted >/dev/null 2>&1; then
            has_cmd pkill && pkill -9 -x danted >/dev/null 2>&1
            sleep 1
        fi
    fi
    rm -f /run/danted.pid 2>/dev/null
    return 0
}

start_dante() {
    local rc=0
    systemctl daemon-reload >/dev/null 2>&1
    systemctl start danted || rc=$?
    sleep 2
    if [[ $rc -eq 0 ]] && dante_running && port_listening "$SOCKS_PORT"; then
        return 0
    fi
    return 1
}

# 启动失败时把真正有用的信息一次打完，别让人再手工去翻 journal
dump_dante_failure() {
    log_error "服务启动失败，诊断信息："
    hr
    log_error "1) danted 配置校验（-V）："
    "$DANTE_BIN" -V -f "$DANTE_CONF" 2>&1 | head -n 20
    hr
    log_error "2) systemd 状态："
    systemctl status danted --no-pager -l 2>/dev/null | head -n 15
    hr
    log_error "3) 最近日志："
    journalctl -xeu danted --no-pager -n 20 2>/dev/null
    hr
    log_error "4) 端口占用（残留进程会导致 Address already in use）："
    local busy
    busy=$(port_listeners "$SOCKS_PORT")
    if [[ -n "$busy" ]]; then
        printf '%s\n' "$busy"
    else
        echo "  端口 ${SOCKS_PORT} 当前无人监听"
    fi
    log_error "5) danted 进程："
    pgrep -ax danted 2>/dev/null | head -n 10 || echo "  无残留进程"
    hr
    log_error "清理后重试： systemctl stop danted; pkill -9 -x danted; socks5 restart"
}

restart_dante() {
    log_info "重启 danted..."
    stop_dante_clean
    if ! start_dante; then
        dump_dante_failure
        return 1
    fi
    log_success "服务运行中，端口 $SOCKS_PORT 监听正常"
    log_usage "service restarted"
    return 0
}

# ============================================================
#  业务：卸载
# ============================================================
do_uninstall() {
    if ! dante_installed && ! [[ -f "$DANTE_CONF" ]]; then
        log_warn "未检测到 SOCKS5 服务"
        return 0
    fi
    load_install_info
    echo
    log_warn "即将卸载 SOCKS5 服务（端口 ${SOCKS_PORT:-?}）"
    echo -n "确认卸载？[y/N]: "
    read -r c
    [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }

    log_step "停止服务"
    systemctl disable --now socks5-shaping >/dev/null 2>&1
    systemctl disable danted >/dev/null 2>&1
    stop_dante_clean

    log_step "清理限速规则"
    shaping_clear "$(resolve_iface)"
    rm -f "$SHAPING_UNIT" "$LIMIT_CONF" "$SHAPING_HELPER"

    log_step "删除 systemd 单元"
    rm -f "$S5_UNIT"
    systemctl daemon-reload
    systemctl reset-failed danted >/dev/null 2>&1

    log_step "处理配置文件"
    if [[ -f "$DANTE_CONF" ]]; then
        local bak="${DANTE_CONF}.uninstall.$(date +%Y%m%d_%H%M%S)"
        cp "$DANTE_CONF" "$bak" 2>/dev/null
        rm -f "$DANTE_CONF"
        log_info "配置已备份到 $bak"
    fi

    echo -n "删除日志 $LOG_FILE 与 logrotate 规则？[y/N]: "
    read -r c
    if [[ "${c,,}" == "y" ]]; then
        rm -f "$LOG_FILE" "$LOGROTATE_FILE"
        log_info "日志已删除"
    else
        log_info "日志已保留"
    fi

    # 清理 /var/log/danted.log.N 轮转残留
    if [[ -f /etc/logrotate.d/danted ]] && grep -q "$LOG_FILE" /etc/logrotate.d/danted 2>/dev/null; then
        rm -f /etc/logrotate.d/danted
    fi

    if [[ "$USE_AUTH" == true && -n "$SOCKS_USER" ]]; then
        echo -n "删除认证用户 $SOCKS_USER？[y/N]: "
        read -r c
        if [[ "${c,,}" == "y" ]]; then
            pkill -u "$SOCKS_USER" >/dev/null 2>&1
            userdel "$SOCKS_USER" >/dev/null 2>&1 && log_info "用户 $SOCKS_USER 已删除"
        else
            log_info "用户 $SOCKS_USER 已保留"
        fi
    fi

    if [[ -n "$SOCKS_PORT" ]]; then
        echo -n "移除防火墙放行规则（端口 $SOCKS_PORT）？[y/N]: "
        read -r c
        if [[ "${c,,}" == "y" ]]; then close_port "$SOCKS_PORT"; else log_info "防火墙规则已保留"; fi
    fi

    echo -n "卸载 dante-server 软件包？[y/N]: "
    read -r c
    if [[ "${c,,}" == "y" ]]; then
        if [[ "$OS" == "rhel" ]] || [[ -f /etc/redhat-release ]]; then
            (command -v dnf >/dev/null 2>&1 && dnf remove -y dante-server) || yum remove -y dante-server
        else
            DEBIAN_FRONTEND=noninteractive apt-get remove -y dante-server
        fi
        log_info "软件包已卸载"
    else
        log_info "软件包已保留"
    fi

    echo -n "删除管理脚本自身与统计数据（$CONFIG_DIR, $SELF_PATH）？[y/N]: "
    read -r c
    if [[ "${c,,}" == "y" ]]; then
        rm -rf "$CONFIG_DIR"
        # Linux 下删除正在运行的脚本本身是安全的（inode 仍被持有）
        rm -f "$SELF_PATH"
        log_info "管理文件已清理"
    else
        log_info "管理文件已保留（如需重装可直接复用）"
    fi

    hr
    log_success "卸载完成"
    log_usage "uninstalled"
}

# ============================================================
#  业务：限速
# ============================================================
limit_status_text() {
    load_limit_conf || true
    if [[ -z "$LIMIT_DOWN$LIMIT_UP" ]]; then
        printf '未启用'
    else
        printf '下载 %s / 上传 %s' "${LIMIT_DOWN:-不限}" "${LIMIT_UP:-不限}"
    fi
}

do_limit() {
    if ! dante_installed; then log_error "尚未安装 SOCKS5，先安装再设置限速"; return 1; fi
    load_install_info
    SOCKS_PORT="${SOCKS_PORT:-1080}"
    load_limit_conf
    LIMIT_IFACE=$(resolve_iface)
    LIMIT_PORT="${LIMIT_PORT:-}"
    [[ -z "$LIMIT_PORT" ]] && LIMIT_PORT="$SOCKS_PORT"
    if [[ -z "$LIMIT_IFACE" ]]; then
        log_error "无法确定出口网卡，限速无法应用（请检查 ip route 输出）"
        return 1
    fi

    while true; do
        echo
        echo -e "${BLUE}端口限速设置${NC}  (端口 ${SOCKS_PORT}, 网卡 ${LIMIT_IFACE})"
        hr
        echo "  当前: $(limit_status_text)"
        hr
        echo "  1) 同时限制下载和上传"
        echo "  2) 只限制下载（服务器 → 客户端）"
        echo "  3) 只限制上传（客户端 → 服务器）"
        echo "  4) 查看当前限速实况（tc）"
        echo "  5) 清除限速"
        echo "  0) 返回"
        echo
        local ch v
        read -r -p "请选择: " ch
        case "$ch" in
            1|2|3)
                echo
                echo "单位写法: 10 = 10Mbps, 800K = 800Kbps, 0 = 不限"
                # 只改指定方向，另一方向必须显式清空（否则会残留上次的值）
                local nd="" nu=""
                while true; do
                    if [[ "$ch" == "1" || "$ch" == "2" ]]; then
                        read -r -p "下载速率（服务器→客户端）: " v
                        nd=$(rate_norm "$v") || continue
                    fi
                    if [[ "$ch" == "1" || "$ch" == "3" ]]; then
                        read -r -p "上传速率（客户端→服务器）: " v
                        nu=$(rate_norm "$v") || continue
                    fi
                    break
                done
                LIMIT_DOWN="$nd"; LIMIT_UP="$nu"
                [[ -z "$LIMIT_DOWN" && -z "$LIMIT_UP" ]] && log_warn "两项都是不限，直接清除限速"

                LIMIT_IFACE=$(resolve_iface)
                [[ -z "$LIMIT_IFACE" ]] && { log_error "网卡探测失败，已取消"; return 1; }
                LIMIT_PORT="$SOCKS_PORT"
                save_limit_conf

                log_step "应用 tc 规则"
                if shaping_apply "$LIMIT_IFACE" "$LIMIT_PORT" "$LIMIT_DOWN" "$LIMIT_UP"; then
                    log_success "限速已生效: $(limit_status_text)"
                else
                    log_error "限速应用失败"
                fi

                write_shaping_unit
                systemctl enable socks5-shaping >/dev/null 2>&1
                systemctl restart socks5-shaping >/dev/null 2>&1
                log_info "已设置开机自动恢复限速"
                log_usage "limit set down=${LIMIT_DOWN:-none} up=${LIMIT_UP:-none}"
                return 0
                ;;
            4)
                echo
                if ! has_cmd tc; then log_error "缺少 tc"; continue; fi
                echo -e "${CYAN}qdisc:${NC}"
                tc qdisc show dev "$LIMIT_IFACE" 2>/dev/null
                echo
                echo -e "${CYAN}class:${NC}"
                tc class show dev "$LIMIT_IFACE" 2>/dev/null
                echo
                echo -e "${CYAN}filter:${NC}"
                tc filter show dev "$LIMIT_IFACE" parent 1: 2>/dev/null
                if [[ -n "$LIMIT_UP" ]]; then
                    echo
                    echo -e "${CYAN}ingress / $IFB_DEV:${NC}"
                    tc filter show dev "$LIMIT_IFACE" parent ffff: 2>/dev/null
                    tc class show dev "$IFB_DEV" 2>/dev/null
                fi
                ;;
            5)
                log_step "清除限速"
                shaping_clear "$(get_iface)"
                LIMIT_DOWN=""; LIMIT_UP=""; LIMIT_PORT="$SOCKS_PORT"; LIMIT_IFACE=$(get_iface)
                save_limit_conf
                systemctl disable --now socks5-shaping >/dev/null 2>&1
                log_success "限速已清除"
                log_usage "limit cleared"
                ;;
            0) return 0 ;;
            *) log_error "无效选择" ;;
        esac
    done
}

# ============================================================
#  查看类
# ============================================================
show_status() {
    echo
    echo -e "${BLUE}SOCKS5 服务状态${NC}"
    hr
    if ! dante_installed; then
        log_warn "未安装"
        return 0
    fi
    dante_running && echo -e "运行状态: ${GREEN}运行中${NC}" || echo -e "运行状态: ${RED}已停止${NC}"
    systemctl is-enabled --quiet danted 2>/dev/null \
        && echo -e "开机自启: ${GREEN}已启用${NC}" || echo -e "开机自启: ${RED}已禁用${NC}"

    if ! load_install_info; then
        log_warn "未找到安装信息（$INSTALL_INFO），以下为推断值；建议执行「修改配置」重写一遍"
    fi
    SOCKS_PORT="${SOCKS_PORT:-1080}"
    echo
    echo -e "${CYAN}配置${NC}"
    echo "  公网 IP:  ${SERVER_IP:-未知}"
    echo "  端口:     $SOCKS_PORT"
    echo "  网卡:     ${INTERFACE:-未知}"
    echo "  认证:     $([[ "$USE_AUTH" == true ]] && echo "用户名密码 (${SOCKS_USER})" || echo "无认证")"
    echo "  安装时间: ${INSTALL_DATE:-未知}"
    port_listening "$SOCKS_PORT" \
        && echo -e "  端口监听: ${GREEN}正常${NC}" || echo -e "  端口监听: ${RED}异常${NC}"
    echo "  限速:     $(limit_status_text)"

    echo
    echo -e "${CYAN}资源占用${NC}"
    local psline
    psline=$(ps -eo %mem,%cpu,comm 2>/dev/null | awk '$3 ~ /^danted/' | head -n1)
    if [[ -n "$psline" ]]; then
        echo "  内存: $(echo "$psline" | awk '{print $1}')%   CPU: $(echo "$psline" | awk '{print $2}')%"
    else
        echo "  进程未运行"
    fi

    echo
    echo -e "${CYAN}当前连接数${NC}"
    if has_cmd ss; then
        local n
        n=$(ss -Htn state established 2>/dev/null | awk -v w=":$SOCKS_PORT" '$4 ~ (w "$")' | wc -l)
        echo "  SOCKS 端口已建立连接: $n"
    fi
    log_usage "status checked"
}

show_info() {
    echo
    echo -e "${BLUE}SOCKS5 连接信息${NC}"
    hr
    if ! load_install_info; then log_error "未找到安装信息，请先安装"; return 1; fi
    echo -e "服务器:  ${GREEN}${SERVER_IP}${NC}"
    echo -e "端口:    ${GREEN}${SOCKS_PORT}${NC}"
    echo -e "协议:    ${GREEN}SOCKS5${NC}"
    if [[ "$USE_AUTH" == true ]]; then
        echo -e "用户名:  ${GREEN}${SOCKS_USER}${NC}"
        echo -e "密码:    ${GREEN}${SOCKS_PASS}${NC}"
    else
        echo -e "认证:    ${RED}无认证${NC}"
    fi
    echo
    echo -e "${CYAN}客户端示例${NC}"
    echo "  curl:  $(curl_hint "$SERVER_IP" "$SOCKS_PORT")"
    echo "  浏览器: SOCKS5  ${SERVER_IP}  ${SOCKS_PORT}  （勾选「代理解析域名 / 远程 DNS」）"
    log_usage "info viewed"
}

show_stats() {
    echo
    echo -e "${BLUE}操作统计${NC}"
    hr
    if [[ ! -f "$STATS_FILE" ]]; then log_warn "暂无记录"; return 0; fi
    echo -e "${CYAN}最近 10 条${NC}"
    tail -n 10 "$STATS_FILE"
    echo
    echo -e "${CYAN}汇总${NC}"
    echo "  总操作:   $(wc -l <"$STATS_FILE")"
    echo "  安装:     $(count_in 'installed' "$STATS_FILE")"
    echo "  卸载:     $(count_in 'uninstalled' "$STATS_FILE")"
    echo "  重启:     $(count_in 'service restarted' "$STATS_FILE")"
    echo "  限速变更: $(count_in 'limit ' "$STATS_FILE")"
    if [[ -f "$LOG_FILE" ]]; then
        echo
        echo -e "${CYAN}连接日志${NC}"
        echo "  累计 connect: $(count_in 'connect' "$LOG_FILE")"
        echo "  今日 connect: $(count_in "$(date +%Y-%m-%d)" "$LOG_FILE")"
    fi
}

show_logs() {
    echo -e "${CYAN}实时日志（Ctrl+C 退出）${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -f "$LOG_FILE"
    else
        journalctl -u danted -f
    fi
}

# ============================================================
#  菜单
# ============================================================
show_menu() {
    load_install_info >/dev/null 2>&1 || true
    local state line
    if dante_installed; then
        if dante_running; then
            state="${GREEN}运行中${NC}  端口 ${SOCKS_PORT:-?}"
        else
            state="${RED}已停止${NC}  端口 ${SOCKS_PORT:-?}"
        fi
    else
        state="${YELLOW}未安装${NC}"
    fi
    line=$(limit_status_text)

    echo
    echo "=================================================="
    echo -e "  ${BOLD}SOCKS5 管理脚本 v${SCRIPT_VERSION}${NC}"
    echo -e "  状态: ${state}"
    echo -e "  限速: ${line}"
    echo "=================================================="
    echo -e "  ${CYAN}1${NC}) 安装 SOCKS5 服务"
    echo -e "  ${CYAN}2${NC}) 修改配置（端口 / 认证 / 重配）"
    echo -e "  ${CYAN}3${NC}) 卸载 SOCKS5 服务"
    echo -e "  ${CYAN}4${NC}) 设置限速"
    echo "  ------------------------------"
    echo -e "  ${CYAN}5${NC}) 查看状态"
    echo -e "  ${CYAN}6${NC}) 查看连接信息"
    echo -e "  ${CYAN}7${NC}) 重启服务"
    echo -e "  ${CYAN}8${NC}) 实时日志"
    echo -e "  ${CYAN}9${NC}) 操作统计"
    echo -e "  ${CYAN}u${NC}) 升级脚本"
    echo -e "  ${CYAN}0${NC}) 退出"
    echo
}

handle_menu() {
    while true; do
        show_menu
        read -r -p "请选择 [0-9/u]: " choice
        case "$choice" in
            1) do_install ;;
            2) do_modify ;;
            3) do_uninstall ;;
            4) do_limit ;;
            5) show_status ;;
            6) show_info ;;
            7) restart_dante ;;
            8) show_logs ;;
            9) show_stats ;;
            u|U|upgrade) do_upgrade ;;
            0) log_info "已退出"; log_usage "exit"; exit 0 ;;
            *) log_error "无效选项，请输入 0-9 或 u" ;;
        esac
        echo
        read -r -p "按回车继续..." -r _
    done
}

# ============================================================
#  命令行
# ============================================================
show_help() {
    cat <<EOF
SOCKS5 管理脚本 v${SCRIPT_VERSION}

用法: $0 [命令] [选项]

命令:
  install, -i            安装 SOCKS5 服务
  modify, -m             修改配置
  uninstall, -u          卸载
  limit, -L              设置端口限速
  status, -s             查看状态
  info                   查看连接信息
  restart, -r            重启服务
  logs, -l               实时日志
  stats                  操作统计
  upgrade, --upgrade     检查并升级脚本（拉取最新版）
  refresh, --refresh     按安装记录重建 danted.conf 与 systemd 单元并重启
  doctor, --doctor       自检：脚本/服务/配置/限速一次列清
  version, --version     显示版本与运行位置（排查版本错配用）
  help, -h               本帮助

install 的非交互选项:
  --port N               SOCKS 端口
  --user NAME            认证用户名（大小写随意，最长 32 位）
  --pass PASS            认证密码（1-64 位，字符不限）
  --no-auth              无认证模式（慎用）

示例:
  $0 install --port 1080 --user u1 --pass Example#2024
  $0 limit               进入限速菜单
  $0                     交互菜单
EOF
}

# install 的非交互参数解析
do_install_noninteractive() {
    shift
    local want_port="" want_user="" want_pass="" no_auth=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)  want_port="$2"; shift 2 ;;
            --user)  want_user="$2"; shift 2 ;;
            --pass)  want_pass="$2"; shift 2 ;;
            --no-auth) no_auth=1; shift ;;
            *) log_error "未知选项: $1"; exit 1 ;;
        esac
    done

    detect_os
    install_dependencies
    detect_iface
    SERVER_IP=$(get_public_ip)

    SOCKS_PORT="${want_port:-1080}"
    if [[ "$no_auth" == "1" ]]; then
        USE_AUTH=false; SOCKS_USER=""; SOCKS_PASS=""
    else
        USE_AUTH=true
        SOCKS_USER="${want_user:-socksuser}"
        SOCKS_PASS="${want_pass:-$(gen_pass)}"
    fi

    echo
    log_info "端口=$SOCKS_PORT  认证=$USE_AUTH  用户=${SOCKS_USER:-无}"
    if [[ "$USE_AUTH" == true ]]; then
        valid_user_name "$SOCKS_USER" || die "用户名被拒：不能为空、不能超过 32 位、不能含冒号或空格、不能以 - 开头"
        valid_password "$SOCKS_PASS" || die "密码最长 64 位"
    fi
    create_system_user || die "认证用户创建失败"
    write_danted_conf
    "$DANTE_BIN" -V -f "$DANTE_CONF" >/dev/null 2>&1 || die "配置校验失败（$DANTE_BIN -V -f $DANTE_CONF 可看详情）"
    write_systemd_unit
    write_logrotate
    open_port "$SOCKS_PORT"
    install_self
    write_shaping_unit
    save_install_info
    systemctl enable danted >/dev/null 2>&1
    stop_dante_clean
    if ! start_dante; then
        dump_dante_failure
        exit 1
    fi
    test_proxy
    show_install_complete
    log_usage "installed port=$SOCKS_PORT auth=$USE_AUTH (cli)"
}

show_version() {
    echo "socks5 管理脚本 v${SCRIPT_VERSION}"
    echo "运行位置: ${BASH_SOURCE[0]:-$0}"
    if [[ -e "$SELF_PATH" ]]; then
        echo "已安装命令: $SELF_PATH (v$(ver_of "$SELF_PATH"))"
    else
        echo "已安装命令: 无（${SELF_PATH} 不存在）"
    fi
    local iv
    iv=$(info_version)
    [[ -n "$iv" ]] && echo "安装记录版本: v$iv"
}

# 自检：把「脚本版本 / 文件完整性 / 已装命令 / 服务 / 配置 / 限速」一次列清
do_doctor() {
    local self="${BASH_SOURCE[0]:-$0}"
    local ok="${GREEN}OK${NC}" bad="${RED}FAIL${NC}" na="${YELLOW}--${NC}"
    echo
    echo -e "${BLUE}socks5 自检${NC}"
    hr

    echo -e "${CYAN}[脚本]${NC}"
    echo "  运行位置: $self"
    echo "  运行版本: v$SCRIPT_VERSION"
    if [[ -f "$self" ]]; then
        if bash -n "$self" 2>/dev/null; then
            echo -e "  语法自检: $ok"
        else
            echo -e "  语法自检: $bad （文件不完整或被截断）"
        fi
        echo "  文件大小: $(wc -c <"$self" 2>/dev/null) 字节"
    fi
    if [[ -e "$SELF_PATH" ]]; then
        echo "  已装命令: $SELF_PATH (v$(ver_of "$SELF_PATH"))"
    else
        echo -e "  已装命令: $bad 缺失"
    fi
    local iv; iv=$(info_version)
    if [[ -n "$iv" ]]; then
        echo "  安装记录: v$iv"
    else
        echo -e "  安装记录: $na 无"
    fi

    echo
    echo -e "${CYAN}[服务]${NC}"
    if dante_installed; then
        dante_running && echo -e "  danted:   $ok 运行中" || echo -e "  danted:   $bad 未运行"
        if [[ -f "$S5_UNIT" ]]; then
            local t km pf
            t=$(sed -n 's/^Type=//p' "$S5_UNIT" | head -n1)
            km=$(sed -n 's/^KillMode=//p' "$S5_UNIT" | head -n1)
            pf=$(grep -c '^PIDFile=' "$S5_UNIT" 2>/dev/null)
            echo "  unit:     Type=${t:-默认} KillMode=${km:-默认} PIDFile=${pf}"
            if [[ "$t" == "simple" && "$pf" == "0" ]]; then
                echo -e "  单元格式: $ok"
            else
                echo -e "  单元格式: ${YELLOW}旧格式，跑 socks5 refresh 修正${NC}"
            fi
        fi
        # 存活时长与重启次数是"能用几秒就断"这类问题的第一手证据：
        # 时长只有几秒 + 重启次数很大 = 进程在反复死
        local since nr up
        since=$(systemctl show danted -p ActiveEnterTimestamp --value 2>/dev/null)
        nr=$(systemctl show danted -p NRestarts --value 2>/dev/null)
        if [[ -n "$since" ]]; then
            up=$(date -d "$since" +%s 2>/dev/null)
            if [[ -n "$up" ]]; then
                echo "  启动于:   $since （已运行 $(( $(date +%s) - up )) 秒）"
            else
                echo "  启动于:   $since"
            fi
        fi
        echo "  重启次数: ${nr:-0}"
        if [[ -n "$nr" && "$nr" =~ ^[0-9]+$ && "$nr" -gt 2 ]]; then
            echo -e "  ${YELLOW}重启次数偏多 → 进程在反复退出，看下面日志${NC}"
        fi
        echo "  最近日志:"
        journalctl -u danted --no-pager -n 8 2>/dev/null | sed 's/^/    /'
    else
        echo -e "  danted:   $na 未安装"
    fi

    echo
    echo -e "${CYAN}[配置]${NC}"
    if [[ -f "$DANTE_CONF" ]]; then
        echo "  $DANTE_CONF: $(wc -l <"$DANTE_CONF") 行"
        local bin="$DANTE_BIN"
        [[ -x "$bin" ]] || bin=$(command -v danted 2>/dev/null)
        if [[ -x "$bin" ]]; then
            if local vl; vl=$("$bin" -V -f "$DANTE_CONF" 2>&1); then
                echo -e "  配置校验: $ok"
            else
                echo -e "  配置校验: $bad"
                printf '    %s\n' "$vl"
            fi
        else
            echo -e "  配置校验: $na 找不到 danted"
        fi
        echo "  监听地址: $(sed -n 's/^internal: //p' "$DANTE_CONF" | head -n1)"
        echo "  出口网卡: $(sed -n 's/^external: //p' "$DANTE_CONF" | head -n1)"
    else
        echo -e "  $DANTE_CONF: $na 不存在"
    fi

    echo
    echo -e "${CYAN}[端口与限速]${NC}"
    local dport=""
    if load_install_info; then
        dport="$SOCKS_PORT"
        echo "  SOCKS 端口: $dport"
        if port_listening "$dport"; then
            echo -e "  监听状态: $ok"
            # 绑在哪个地址上很关键：只听 127.0.0.1 的话外部必然连不上
            local binds
            if has_cmd ss; then
                binds=$(ss -H -ltn 2>/dev/null | awk -v w=":$dport" '$4 ~ (w "$") {print $4}' | sort -u | tr '\n' ' ')
            fi
            echo "  绑定地址: ${binds:-未知}"
            case "$binds" in
                *"0.0.0.0:$dport"*|*"[::]:$dport"*|*"*:$dport"*) ;;
                "") ;;
                *"127.0.0.1:$dport"*|*"[::1]:$dport"*)
                    echo -e "  ${RED}只监听回环，外部永远连不上${NC}" ;;
            esac
        else
            echo -e "  监听状态: $bad 未监听"
        fi
    else
        echo -e "  安装信息: $na 缺失"
    fi
    echo "  限速: $(limit_status_text)"

    echo
    echo -e "${CYAN}[外部可达性]${NC}"
    if [[ -n "$dport" ]]; then
        if tcp_probe 127.0.0.1 "$dport"; then
            echo -e "  本机 127.0.0.1:$dport  $ok"
        else
            echo -e "  本机 127.0.0.1:$dport  $bad"
        fi
        if [[ -n "$SERVER_IP" && "$SERVER_IP" != "0.0.0.0" ]]; then
            if tcp_probe "$SERVER_IP" "$dport"; then
                echo -e "  公网 $SERVER_IP:$dport  $ok"
            else
                echo -e "  公网 $SERVER_IP:$dport  $bad"
                echo -e "  ${YELLOW}本机通公网不通 → 云安全组/上游防火墙，去控制台放行入方向 TCP $dport${NC}"
            fi
        fi
    fi

    echo
    echo -e "${CYAN}[防火墙]${NC}"
    local fw_any=0
    if has_cmd ufw; then
        fw_any=1
        echo "  ufw: $(ufw status 2>/dev/null | head -n1 | sed 's/^Status: //')"
        ufw status 2>/dev/null | grep -E "^${dport}(/tcp)?" | head -n2 | sed 's/^/    /'
    fi
    if has_cmd firewall-cmd; then
        fw_any=1
        local fs
        fs=$(firewall-cmd --state 2>/dev/null)
        echo "  firewalld: ${fs:-未运行}"
        if [[ "$fs" == "running" ]]; then
            echo "    已放行端口: $(firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -E "^${dport}/" | tr '\n' ' ')"
        fi
    fi
    if has_cmd iptables; then
        fw_any=1
        local icnt
        icnt=$(iptables -S INPUT 2>/dev/null | grep -c -- "--dport ${dport}")
        echo "  iptables INPUT 匹配 ${dport} 的规则: ${icnt:-0} 条"
    fi
    [[ $fw_any -eq 0 ]] && echo -e "  $na 未检测到防火墙工具"
    echo -e "  ${YELLOW}提示: 操作系统内的防火墙放行 ≠ 云安全组放行，两者都要开${NC}"

    hr
    return 0
}

main() {
    need_root

    # systemd 调用的内部命令，不写统计、不进菜单
    case "${1:-}" in
        _apply-limit) limit_apply_from_conf; exit 0 ;;
        _clear-limit) shaping_clear "$(get_iface)"; exit 0 ;;
    esac

    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
    log_usage "run: ${*:-menu}"

    # 命令缺失就顺手装上（curl|bash 方式运行过但没装的情况）
    # 这里不能把输出丢掉：版本不一致的告警必须让人看见
    [[ -x "$SELF_PATH" ]] || install_self

    case "${1:-}" in
        "")                  handle_menu ;;
        install|--install|-i) do_install_noninteractive "$@" ;;
        modify|--modify|-m)  do_modify ;;
        uninstall|--uninstall|-u) do_uninstall ;;
        limit|--limit|-L)    do_limit ;;
        status|--status|-s)  show_status ;;
        info|--info)         show_info ;;
        restart|--restart|-r) load_install_info; restart_dante ;;
        logs|--logs|-l)      show_logs ;;
        stats|--stats)       show_stats ;;
        upgrade|--upgrade)   do_upgrade "${2:-}" ;;
        refresh|--refresh)   do_refresh ;;
        version|--version)   show_version ;;
        doctor|--doctor)     do_doctor ;;
        help|--help|-h)      show_help ;;
        *) log_error "未知命令: $1"; show_help; exit 1 ;;
    esac
}

trap 'echo; log_info "已中断"; exit 130' INT TERM

# 被 source 时只加载函数，不执行主流程（便于单测）
if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    trap 'echo; log_info "已中断"; exit 130' INT TERM
    main "$@"
fi
