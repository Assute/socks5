#!/usr/bin/env bash
# ============================================================
#  SOCKS5 服务管理脚本 v3.3   (Dante SOCKS5)
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
LOG_FILE="/var/log/danted.log"
LOGROTATE_FILE="/etc/logrotate.d/socks5-danted"
IFB_DEV="ifb0"
SCRIPT_VERSION="3.3"

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
        printf 'SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"
    } >"$INSTALL_INFO"
    chmod 600 "$INSTALL_INFO"
}

load_install_info() {
    [[ -f "$INSTALL_INFO" ]] || return 1
    # shellcheck disable=SC1090
    source "$INSTALL_INFO" 2>/dev/null
    return 0
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
        local tmp=""
        tmp=$(mktemp /tmp/socks5.XXXXXX 2>/dev/null) || return 0
        if has_cmd curl && curl -fsSL -o "$tmp" "$SELF_URL" 2>/dev/null \
            && head -n1 "$tmp" 2>/dev/null | grep -q '^#!.*bash' \
            && grep -q 'SCRIPT_VERSION=' "$tmp" 2>/dev/null; then
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

[Service]
Type=simple
ExecStart=$DANTE_BIN -f $DANTE_CONF
ExecReload=/bin/kill -HUP \$MAINPID
# danted 会派生多个子进程（mother/negotiate/request/io），
# 必须让 systemd 管住整个 cgroup，否则停止后子进程继续占着端口
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=15
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    log_info "systemd 单元已写入（Type=simple）"
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
        0) log_success "代理连通性测试通过" ;;
        5|6) log_error "代理握手/认证失败（rc=$rc），检查用户名密码与 PAM" ;;
        7)  log_warn "本地连接不上端口（rc=7），检查 danted 状态" ;;
        *)  log_warn "连通性测试未通过（rc=$rc），可能是出口网络受限" ;;
    esac
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
    echo -e "  ${CYAN}0${NC}) 退出"
    echo
}

handle_menu() {
    while true; do
        show_menu
        read -r -p "请选择 [0-9]: " choice
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
            0) log_info "已退出"; log_usage "exit"; exit 0 ;;
            *) log_error "无效选项，请输入 0-9" ;;
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
  version, --version     显示版本与运行位置（排查版本错配用）
  help, -h               本帮助

install 的非交互选项:
  --port N               SOCKS 端口
  --user NAME            认证用户名（大小写随意，最长 32 位）
  --pass PASS            认证密码（1-64 位，字符不限）
  --no-auth              无认证模式（慎用）

示例:
  $0 install --port 1080 --user u1 --pass p123456
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
    [[ -x "$SELF_PATH" ]] && echo "已安装命令: $SELF_PATH"
    [[ -f "$INSTALL_INFO" ]] && echo "安装记录: $INSTALL_INFO" && grep '^SCRIPT_VERSION=' "$INSTALL_INFO" 2>/dev/null | sed 's/^/  /'
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
    [[ -x "$SELF_PATH" ]] || install_self >/dev/null 2>&1

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
        version|--version)   show_version ;;
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
