#!/usr/bin/env bash
# ============================================================
#  SOCKS5 管理脚本 v1.4   (gost v2 后端)
#
#  系统: Debian / Ubuntu / CentOS / Rocky / Alma / RHEL (systemd)
#  功能: 安装 · 修改 · 卸载 · 限速(tc) · 状态 · 自检 · 升级
#
#  与 dante 版的区别：gost 是静态 Go 二进制，不依赖 PAM、
#  不创建系统账号、不碰 /etc/passwd，凭据只存在 600 权限的
#  JSON 配置里（不写进 systemd 命令行）。
#
#  用法:  bash gost.sh            # 交互菜单
#         bash gost.sh install --port 8443 --user u1 --pass p1
# ============================================================

CONFIG_DIR="/etc/socks5-gost"
INSTALL_INFO="$CONFIG_DIR/install.conf"
LIMIT_CONF="$CONFIG_DIR/limit.conf"
ALLOW_FILE="$CONFIG_DIR/allow.txt"
STATS_FILE="$CONFIG_DIR/usage.log"

GOST_BIN="/usr/local/bin/gost"
GOST_CONF_DIR="/etc/gost"
GOST_CONF="$GOST_CONF_DIR/gost.json"
UNIT="/etc/systemd/system/gost.service"

SHAPING_UNIT="/etc/systemd/system/gost-shaping.service"
SHAPING_HELPER="/usr/local/sbin/gost-shaping"
LOG_FILE="/var/log/gost-access.log"
LOGROTATE_FILE="/etc/logrotate.d/socks5-gost"
IFB_DEV="ifb0"

SELF_PATH="/usr/local/sbin/socks5"
SELF_NAME="gost.sh"
SELF_URL="https://raw.githubusercontent.com/Assute/socks5/main/gost.sh"
SELF_API_URL="https://api.github.com/repos/Assute/socks5/contents/gost.sh?ref=main"

GOST_VER="2.12.0"
SCRIPT_VERSION="1.4"
BIG_RATE="10000mbit"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

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

count_in() {
    local n
    n=$(grep -c -- "$1" "$2" 2>/dev/null)
    printf '%s' "${n:-0}"
}

# ---------- 基础 ----------
need_root() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] && die "请使用 root 运行：sudo bash $0"
    return 0
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_os() {
    if [[ -f /etc/redhat-release ]]; then
        OS="rhel"; command -v dnf >/dev/null 2>&1 && PM=dnf || PM=yum
    elif [[ -f /etc/debian_version ]]; then
        OS="debian"; PM=apt-get
    else
        OS="other"; PM=""
    fi
    log_info "系统: $OS"
}

pkg_install() {
    [[ -z "$PM" ]] && { log_warn "未知发行版，请手动确保安装 curl"; return 0; }
    if [[ "$OS" == "rhel" ]]; then
        $PM install -y "$@"
    else
        DEBIAN_FRONTEND=noninteractive $PM install -y "$@"
    fi
}

gen_pass() { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16; }

get_iface() {
    local i
    i=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    [[ -z "$i" ]] && i=$(ip -4 route show default 2>/dev/null | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -n1)
    [[ -z "$i" ]] && i=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" {print $2; exit}')
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

# ---------- 端口探测（按第 4 列匹配，ss 加 -p 后行尾是 users:(...)） ----------
port_listeners() {
    local p="$1"
    if has_cmd ss; then
        ss -H -ltnp 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")'
    elif has_cmd netstat; then
        netstat -ltnp 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")'
    fi
}

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
    if has_cmd ss; then
        ss -H -ltnu 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")' | grep -q .
    elif has_cmd netstat; then
        netstat -ltnu 2>/dev/null | awk -v w=":$p" '$4 ~ (w "$")' | grep -q .
    else
        return 1
    fi
}

# 只测 TCP 能否建立；安全组拦截的特征是"本机通、公网不通"
tcp_probe() {
    local h="$1" p="$2"
    [[ -z "$h" || -z "$p" ]] && return 1
    if has_cmd timeout; then
        timeout 6 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null
    else
        (exec 3<>/dev/tcp/"$h"/"$p") 2>/dev/null
    fi
}

# ---------- 凭据 ----------
# gost 的凭据放在 URL 里（socks5://user:pass@:port），
# 所以必须百分号编码，否则 @ : / 会把 URL 结构撕坏。
# 校验只挡真正会出问题的东西：空值、超长、控制字符（换行/制表等）。
# 中文、空格、符号都放行 —— urlenc 会把它们编码成 %XX，gost 能正确解码。
#
# 注意：不能用 [[ =~ [[:cntrl:]] ]] 判断控制字符。
# 在 C locale 下 bash 的正则引擎会把 UTF-8 的部分字节
# （例如「文」的 0x96）也判成 cntrl，导致中文用户名被误拒。
# tr 在 LC_ALL=C 下按字节分类，只处理 0x00-0x1F 和 0x7F，不误伤多字节字符。
has_ctl() {
    local s="$1"
    [[ "$(printf '%s' "$s" | LC_ALL=C tr -d '[:cntrl:]')" != "$s" ]]
}

valid_user_name() {
    local v="$1"
    [[ -z "$v" ]] && return 1
    [[ ${#v} -gt 64 ]] && return 1
    has_ctl "$v" && return 1
    return 0
}

valid_password() {
    local v="$1"
    [[ -z "$v" ]] && return 1
    [[ ${#v} -gt 128 ]] && return 1
    has_ctl "$v" && return 1
    return 0
}

# 没给用户名时生成一个随机的，不再用固定的 socksuser
gen_user() { printf 'u%s' "$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8)"; }

urlenc() {
    local s="$1" out="" i c
    local LC_ALL=C
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

# ============================================================
#  目标白名单
#
#  gost 的 bypass 能按目标地址过滤，实测（v2.12.0）得出三个要点：
#    1) 内联值加 ~ 前缀才是白名单：bypass=~.example.com
#    2) 值若为文件路径，~ 会被忽略 —— 文件里必须写 reverse true
#    3) .example.com 匹配主域与一级子域；*.example.com 只匹配一级子域，
#       不匹配主域。所以 *.x 统一归一成 .x，多覆盖主域本身。
#       实测不支持二级以上（a.b.x.com 匹配不到）。
# ============================================================
allow_init() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    chmod 700 "$CONFIG_DIR" 2>/dev/null
    [[ -f "$ALLOW_FILE" ]] && return 0
    cat >"$ALLOW_FILE" <<'EOF'
# ===== SOCKS5 目标白名单 =====
# 只有下面列出的目标能被代理访问，其余一律拒绝。
#
# 语法：
#   .example.com     匹配 example.com 及其一级子域（www.example.com）
#   *.example.com    同上，脚本会自动改写成 .example.com
#   1.2.3.4          单个 IP
#   10.0.0.0/8       网段
#
# 限制：gost 不支持二级以上子域，a.b.example.com 这种方式匹配不到。
#
# 下面两行是白名单开关，不要删：
reload 10s
reverse true
EOF
    chmod 600 "$ALLOW_FILE"
}

# 只输出规则行（去注释、空行和开关指令）
allow_rules() {
    [[ -f "$ALLOW_FILE" ]] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$ALLOW_FILE" 2>/dev/null \
        | grep -vE '^[[:space:]]*(reload|reverse)([[:space:]]|$)' || true
}

allow_count() { allow_rules | grep -c . || true; }

allow_enabled() { [[ "$(allow_count)" -gt 0 ]]; }

allow_status_text() {
    if allow_enabled; then
        printf '已启用（%s 条规则）' "$(allow_count)"
    else
        printf '未启用（放行全部目标）'
    fi
}

# 归一化：*.x → .x；去空白
allow_normalize() {
    local r
    r=$(printf '%s' "$1" | tr -d ' \t\r\n')
    [[ -z "$r" ]] && return 1
    case "$r" in
        \*.*) r=".${r#\*.}" ;;
    esac
    printf '%s' "$r"
}

allow_add() {
    allow_init
    local raw norm
    for raw in "$@"; do
        norm=$(allow_normalize "$raw") || continue
        if allow_rules | grep -qxF -- "$norm"; then
            log_info "已存在: $norm"
            continue
        fi
        printf '%s\n' "$norm" >>"$ALLOW_FILE"
        log_success "已添加: $norm"
    done
}

allow_remove() {
    allow_init
    local norm tmp
    norm=$(allow_normalize "$1") || return 1
    tmp=$(mktemp) || return 1
    grep -vxF -- "$norm" "$ALLOW_FILE" >"$tmp" 2>/dev/null || true
    cat "$tmp" >"$ALLOW_FILE"
    rm -f "$tmp"
    log_info "已删除: $norm"
}

# 清空规则但保留文件头与开关（= 关闭白名单，放行全部）
allow_clear() {
    allow_init
    local tmp
    tmp=$(mktemp) || return 1
    awk '
        /^[[:space:]]*#/ { print; next }
        /^[[:space:]]*$/ { print; next }
        /^[[:space:]]*(reload|reverse)([[:space:]]|$)/ { print; next }
        { next }
    ' "$ALLOW_FILE" >"$tmp"
    cat "$tmp" >"$ALLOW_FILE"
    rm -f "$tmp"
    log_warn "白名单已清空，当前放行全部目标"
}

# 生成 node URL 上要追加的参数；未启用时输出空
bypass_param() {
    allow_enabled || return 0
    printf '?bypass=%s' "$ALLOW_FILE"
}

allow_show() {
    allow_init
    echo
    echo -e "${CYAN}目标白名单${NC}  ($ALLOW_FILE)"
    hr
    echo "  状态: $(allow_status_text)"
    echo
    if allow_enabled; then
        local i=1 r
        while IFS= read -r r; do
            printf '  %2d) %s\n' "$i" "$r"
            i=$((i + 1))
        done < <(allow_rules)
    else
        echo "  （无规则，等于不限制目标）"
    fi
    hr
    echo "  提示: *.x.com 会自动按 .x.com 处理（覆盖主域 + 一级子域）"
    echo "        文件改动后 10 秒内自动生效（reload 10s）"
}

do_allow() {
    allow_init
    local ch v
    while true; do
        echo
        echo -e "${BLUE}白名单管理${NC}  当前: $(allow_status_text)"
        hr
        echo "  1) 查看规则"
        echo "  2) 添加域名 / IP"
        echo "  3) 删除规则"
        echo "  4) 清空（改回放行全部目标）"
        echo "  5) 重新应用到服务"
        echo "  0) 返回"
        echo
        read -r -p "请选择: " ch
        case "$ch" in
            1) allow_show ;;
            2)
                echo "  可一次填多个，用空格或逗号分隔；支持 *.example.com"
                read -r -p "  域名: " v
                v="${v//,/ }"
                # shellcheck disable=SC2086
                allow_add $v
                apply_allow
                ;;
            3)
                allow_show
                read -r -p "  要删除的规则: " v
                allow_remove "$v"
                apply_allow
                ;;
            4)
                read -r -p "  确认清空白名单？之后任何目标都能走代理 [y/N]: " v
                [[ "${v,,}" != "y" ]] && { log_info "已取消"; continue; }
                allow_clear
                apply_allow
                ;;
            5) apply_allow ;;
            0) return 0 ;;
            *) log_error "无效选择" ;;
        esac
    done
}

# 把白名单写进 gost 配置并重启（bypass 是启动参数，改文件靠 reload 只对部分场景有效，
# 参数本身变了必须重启才稳妥）
apply_allow() {
    write_gost_conf
    if gost_running; then
        restart_gost && {
            log_success "已应用，白名单: $(allow_status_text)"
            if allow_enabled; then
                echo
                log_warn "注意：现在只有下列目标能被访问，其余一律被拒绝"
                log_warn "客户端的「节点测速 / 延迟测试」会失败 —— 它测的是自己的测试地址，"
                log_warn "不在你的列表里就会显示节点不可用，这不代表服务有问题"
                test_whitelist
            fi
        }
    else
        log_info "配置已更新，服务未运行，下次启动生效"
    fi
}

# ---------- 配置读写 ----------
save_install_info() {
    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
    {
        printf 'PORT=%q\n'       "$PORT"
        printf 'USER_NAME=%q\n'  "$USER_NAME"
        printf 'PASS_WORD=%q\n'  "$PASS_WORD"
        printf 'USE_AUTH=%q\n'   "$USE_AUTH"
        printf 'SERVER_IP=%q\n'  "$SERVER_IP"
        printf 'INTERFACE=%q\n'  "$INTERFACE"
        printf 'INSTALL_DATE=%q\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'MANAGER_VERSION=%q\n' "$SCRIPT_VERSION"
    } >"$INSTALL_INFO"
    chmod 600 "$INSTALL_INFO"
}

load_install_info() {
    [[ -f "$INSTALL_INFO" ]] || return 1
    # 保护运行版本不被数据文件里的同名键覆盖
    local _sv="$SCRIPT_VERSION"
    # shellcheck disable=SC1090
    source "$INSTALL_INFO" 2>/dev/null
    SCRIPT_VERSION="$_sv"
    return 0
}

info_version() {
    [[ -f "$INSTALL_INFO" ]] || return 0
    local v
    v=$(sed -n 's/^MANAGER_VERSION=//p' "$INSTALL_INFO" 2>/dev/null | tr -d "'\"" | head -n1)
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

limit_status_text() {
    load_limit_conf || true
    if [[ -z "$LIMIT_DOWN$LIMIT_UP" ]]; then
        printf '未启用'
    else
        printf '下载 %s / 上传 %s' "${LIMIT_DOWN:-不限}" "${LIMIT_UP:-不限}"
    fi
}

gost_installed() { [[ -f "$UNIT" ]] && [[ -x "$GOST_BIN" ]]; }
gost_running()   { systemctl is-active --quiet gost 2>/dev/null; }

# ============================================================
#  下载 gost
#  原脚本用的 ghproxy.com / mirror.ghproxy.com 已失效，
#  这里换成实测可用的源，并做 sha256 校验。
# ============================================================
gost_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "armv7" ;;
        armv6l) echo "armv6" ;;
        i386|i686) echo "386" ;;
        *) return 1 ;;
    esac
}

gost_urls() {
    local arch="$1" f="gost_${GOST_VER}_linux_${arch}.tar.gz"
    local gh="https://github.com/ginuerzh/gost/releases/download/v${GOST_VER}/${f}"
    printf '%s\n' \
        "$gh" \
        "https://ghfast.top/${gh}" \
        "https://gh-proxy.com/${gh}"
}

download_gost() {
    local arch ftmp cfmtmp url sha_ok=0
    arch=$(gost_arch) || die "不支持的架构: $(uname -m)"
    log_info "目标架构: linux_${arch}"

    ftmp=$(mktemp /tmp/gost.XXXXXX.tar.gz) || die "无法创建临时文件"
    cfmtmp=$(mktemp /tmp/gostsum.XXXXXX) || die "无法创建临时文件"

    local gh="https://github.com/ginuerzh/gost/releases/download/v${GOST_VER}"
    local fname="gost_${GOST_VER}_linux_${arch}.tar.gz"

    # 先取官方校验值（有就校验，没有就只告警）
    for base in "$gh" "https://ghfast.top/${gh}"; do
        if curl -fsSL --max-time 20 "$base/checksums.txt" -o "$cfmtmp" 2>/dev/null \
            && grep -q "$fname" "$cfmtmp" 2>/dev/null; then
            sha_ok=1
            break
        fi
    done

    local ok=0
    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        log_info "下载: ${url%%/v${GOST_VER}*}…"
        if curl -fsSL --max-time 120 "$url" -o "$ftmp" 2>/dev/null && [[ -s "$ftmp" ]]; then
            if tar -tzf "$ftmp" >/dev/null 2>&1; then
                ok=1
                break
            fi
            log_warn "文件损坏，换下一个源"
        else
            log_warn "下载失败，换下一个源"
        fi
    done < <(gost_urls "$arch")

    [[ $ok -eq 1 ]] || {
        rm -f "$ftmp" "$cfmtmp"
        die "所有下载源都失败。可手动下载 $fname 放到 $GOST_BIN"
    }

    if [[ $sha_ok -eq 1 ]]; then
        local want got
        want=$(grep "$fname" "$cfmtmp" | awk '{print $1}' | head -n1)
        got=$(sha256sum "$ftmp" | awk '{print $1}')
        if [[ "$want" == "$got" ]]; then
            log_success "sha256 校验通过"
        else
            rm -f "$ftmp" "$cfmtmp"
            die "sha256 不匹配（期望 $want，实际 $got），拒绝安装"
        fi
    else
        log_warn "未能获取官方 checksums.txt，跳过校验"
    fi

    local tmpd
    tmpd=$(mktemp -d /tmp/gostx.XXXXXX) || die "无法创建临时目录"
    tar -zxf "$ftmp" -C "$tmpd" gost || { rm -rf "$tmpd" "$ftmp" "$cfmtmp"; die "解压失败"; }
    install -m 0755 "$tmpd/gost" "$GOST_BIN" || { rm -rf "$tmpd" "$ftmp" "$cfmtmp"; die "安装二进制失败"; }
    rm -rf "$tmpd" "$ftmp" "$cfmtmp"

    "$GOST_BIN" -V 2>/dev/null | head -n1 | sed 's/^/  /'
    log_success "gost 已安装: $GOST_BIN"
}

# ============================================================
#  配置与单元
# ============================================================
write_gost_conf() {
    log_step "写入 gost 配置"
    mkdir -p "$GOST_CONF_DIR"; chmod 700 "$GOST_CONF_DIR"

    local node
    if [[ "$USE_AUTH" == true ]]; then
        # 凭据做百分号编码，避免 @ : / 破坏 URL 结构
        node="socks5://$(urlenc "$USER_NAME"):$(urlenc "$PASS_WORD")@:${PORT}"
    else
        node="socks5://:${PORT}"
    fi
    # 白名单以启动参数形式挂上去；未启用时 bypass_param 输出空
    node="${node}$(bypass_param)"

    # 凭据只放这里，权限 600，不进 systemd 命令行
    printf '{"ServeNodes":["%s"]}\n' "$node" >"$GOST_CONF"
    chmod 600 "$GOST_CONF"
    log_info "配置已写入 $GOST_CONF（权限 600）"
    log_info "目标白名单: $(allow_status_text)"
}

write_unit() {
    cat >"$UNIT" <<EOF
[Unit]
Description=gost SOCKS5 proxy
Documentation=https://github.com/ginuerzh/gost
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$GOST_BIN -C $GOST_CONF
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=15
# always 而不是 on-failure：被外部 SIGKILL 时退出码可能仍为 0，
# on-failure 不会重启，服务就永久躺着
Restart=always
RestartSec=5
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
        log_info "UFW: 已放行 ${p}/tcp"
        return 0
    }
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
        log_info "firewalld: 已放行 ${p}/tcp"
        return 0
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
            || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
        { mkdir -p /etc/iptables 2>/dev/null;
          { netfilter-persistent save >/dev/null 2>&1 || { iptables-save >/etc/iptables/rules.v4; }; } 2>/dev/null; }
        log_info "iptables: 已放行 ${p}/tcp"
        return 0
    fi
    log_warn "未检测到防火墙工具，请自行放行端口 $p"
}

close_port() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "${p}/tcp" >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
    if command -v iptables >/dev/null 2>&1; then
        local n=0
        while [[ $n -lt 20 ]] && iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || break
            n=$((n + 1))
        done
    fi
    log_info "已清理端口 $p 的放行规则"
}

# ============================================================
#  限速：只匹配 SOCKS 端口，不整形整块网卡（否则连 SSH 一起限）
#    出方向：源端口 == PORT   → 下载
#    入方向：目标端口 == PORT → 上传（经 ifb 中转）
# ============================================================
rate_norm() {
    local v num unit
    v=$(printf '%s' "$1" | tr -d ' ' | tr 'A-Z' 'a-z')
    [[ -z "$v" || "$v" == "0" ]] && return 0
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
    tc qdisc del dev "$ifc" root >/dev/null 2>&1
    tc qdisc del dev "$ifc" ingress >/dev/null 2>&1
    tc qdisc del dev "$IFB_DEV" root >/dev/null 2>&1
    ip link set "$IFB_DEV" down >/dev/null 2>&1
    return 0
}

shaping_apply() {
    local ifc="$1" port="$2" down="$3" up="$4" rc=0

    has_cmd tc || { log_error "缺少 tc（iproute2 未安装）"; return 1; }
    [[ -z "$ifc" ]] && { log_error "无法确定网卡"; return 1; }
    [[ -z "$port" ]] && { log_error "缺少端口"; return 1; }
    [[ -z "$down" && -z "$up" ]] && { shaping_clear "$ifc"; return 0; }

    shaping_clear "$ifc"

    if [[ -n "$down" ]]; then
        tc qdisc add dev "$ifc" root handle 1: htb default 30 2>/dev/null || {
            log_error "创建出方向 htb 失败"; return 1; }
        # burst/cburst 必须显式给：不写时内核按 rate 推算，
        # 低速率下可能小于一个 MTU，结果不是限速而是全丢包
        tc class add dev "$ifc" parent 1:   classid 1:1  htb rate "$BIG_RATE" ceil "$BIG_RATE" burst 32k cburst 32k 2>/dev/null
        tc class add dev "$ifc" parent 1:1 classid 1:10 htb rate "$down" ceil "$down" burst 32k cburst 32k 2>/dev/null
        tc class add dev "$ifc" parent 1:1 classid 1:30 htb rate "$BIG_RATE" ceil "$BIG_RATE" burst 32k cburst 32k 2>/dev/null
        tc qdisc add dev "$ifc" parent 1:10 fq_codel limit 10240 2>/dev/null
        tc qdisc add dev "$ifc" parent 1:30 fq_codel limit 10240 2>/dev/null
        tc filter add dev "$ifc" parent 1: protocol ip prio 1 u32 \
            match ip sport "$port" 0xffff flowid 1:10 2>/dev/null
        [[ $? -ne 0 ]] && { log_warn "出方向过滤器添加失败"; rc=1; }
    fi

    if [[ -n "$up" ]]; then
        modprobe ifb >/dev/null 2>&1
        ip link show "$IFB_DEV" >/dev/null 2>&1 || ip link add "$IFB_DEV" type ifb 2>/dev/null
        ip link show "$IFB_DEV" >/dev/null 2>&1 || { log_error "ifb 设备创建失败"; return 1; }
        ip link set "$IFB_DEV" up 2>/dev/null

        tc qdisc add dev "$ifc" handle ffff: ingress 2>/dev/null
        tc filter add dev "$ifc" parent ffff: protocol ip prio 1 u32 \
            match ip dport "$port" 0xffff \
            action mirred egress redirect dev "$IFB_DEV" 2>/dev/null
        [[ $? -ne 0 ]] && { log_warn "入方向重定向失败"; rc=1; }

        tc qdisc add dev "$IFB_DEV" root handle 2: htb default 10 2>/dev/null
        tc class add dev "$IFB_DEV" parent 2:   classid 2:1  htb rate "$BIG_RATE" ceil "$BIG_RATE" burst 32k cburst 32k 2>/dev/null
        tc class add dev "$IFB_DEV" parent 2:1 classid 2:10 htb rate "$up" ceil "$up" burst 32k cburst 32k 2>/dev/null
        tc qdisc add dev "$IFB_DEV" parent 2:10 fq_codel limit 10240 2>/dev/null
    fi

    return $rc
}

# 自包含 shim：开机由 systemd 调用，不依赖本脚本位置
write_shaping_helper() {
    cat >"$SHAPING_HELPER" <<EOS
#!/bin/sh
# 由 socks5(gost) 管理脚本 v$SCRIPT_VERSION 生成，重新设置限速会覆盖
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
    tc class add dev "\$iface" parent 1:   classid 1:1  htb rate "\$BIG" ceil "\$BIG" burst 32k cburst 32k 2>/dev/null
    tc class add dev "\$iface" parent 1:1 classid 1:10 htb rate "\$down" ceil "\$down" burst 32k cburst 32k 2>/dev/null
    tc class add dev "\$iface" parent 1:1 classid 1:30 htb rate "\$BIG" ceil "\$BIG" burst 32k cburst 32k 2>/dev/null
    tc qdisc add dev "\$iface" parent 1:10 fq_codel limit 10240 2>/dev/null
    tc qdisc add dev "\$iface" parent 1:30 fq_codel limit 10240 2>/dev/null
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
    tc class add dev "\$IFB" parent 2:   classid 2:1  htb rate "\$BIG" ceil "\$BIG" burst 32k cburst 32k 2>/dev/null
    tc class add dev "\$IFB" parent 2:1 classid 2:10 htb rate "\$up" ceil "\$up" burst 32k cburst 32k 2>/dev/null
    tc qdisc add dev "\$IFB" parent 2:10 fq_codel limit 10240 2>/dev/null
fi

exit 0
EOS
    chmod 0755 "$SHAPING_HELPER"
}

write_shaping_unit() {
    write_shaping_helper
    cat >"$SHAPING_UNIT" <<EOF
[Unit]
Description=gost SOCKS port rate limit (tc HTB)
After=network-online.target gost.service
Wants=network-online.target
PartOf=gost.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SHAPING_HELPER apply
ExecStop=$SHAPING_HELPER clear

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

limit_apply_from_conf() {
    load_limit_conf || return 0
    [[ -z "$LIMIT_IFACE" ]] && return 0
    ip link show "$LIMIT_IFACE" >/dev/null 2>&1 || LIMIT_IFACE=$(get_iface)
    [[ -z "$LIMIT_DOWN" && -z "$LIMIT_UP" ]] && { shaping_clear "$LIMIT_IFACE"; return 0; }
    shaping_apply "$LIMIT_IFACE" "$LIMIT_PORT" "$LIMIT_DOWN" "$LIMIT_UP"
}

# ---------- 服务控制 ----------
stop_gost_clean() {
    systemctl stop gost >/dev/null 2>&1
    systemctl reset-failed gost >/dev/null 2>&1
    if has_cmd pgrep && pgrep -x gost >/dev/null 2>&1; then
        log_warn "清理残留 gost 进程"
        has_cmd pkill && pkill -x gost >/dev/null 2>&1
        sleep 1
        pgrep -x gost >/dev/null 2>&1 && has_cmd pkill && pkill -9 -x gost >/dev/null 2>&1
    fi
    return 0
}

start_gost() {
    systemctl daemon-reload >/dev/null 2>&1
    systemctl start gost || return 1
    sleep 2
    gost_running && port_listening "$PORT"
}

dump_failure() {
    log_error "服务启动失败，诊断："
    hr
    log_error "1) systemd 状态"
    systemctl status gost --no-pager -l 2>/dev/null | head -n 15
    hr
    log_error "2) 最近日志"
    journalctl -xeu gost --no-pager -n 20 2>/dev/null
    hr
    log_error "3) 端口占用"
    local busy
    busy=$(port_listeners "$PORT")
    [[ -n "$busy" ]] && printf '%s\n' "$busy" || echo "  端口 ${PORT} 无人监听"
    hr
    log_error "4) 配置"
    [[ -f "$GOST_CONF" ]] && sed 's#'"$GOST_CONF"'#'"$GOST_CONF"'#' "$GOST_CONF" | sed 's#://[^@]*@#://***@#' | sed 's/^/  /'
}

restart_gost() {
    log_info "重启 gost..."
    stop_gost_clean
    if ! start_gost; then
        dump_failure
        return 1
    fi
    log_success "运行中，端口 $PORT 监听正常"
    log_usage "service restarted"
}

# ---------- 测试 ----------
# 取一条白名单里的域名规则，用于测试；优先取域名而不是 IP/网段
allow_first_domain() {
    allow_rules 2>/dev/null | grep -E '^\.?[A-Za-z0-9*-]+\.[A-Za-z]' | head -n1 \
        | sed 's/^\.//; s/^\*\.//'
}

# 白名单自检：挑一条列表内的域名应放行，一个必定不在列表里的域名应被拒
test_whitelist() {
    allow_enabled || return 0
    has_cmd curl || return 0
    local dom rc_a rc_d
    dom=$(allow_first_domain)
    log_info "白名单自检（共 $(allow_count) 条规则）"

    if [[ -n "$dom" ]]; then
        local ua=()
        [[ "$USE_AUTH" == true ]] && ua=(--proxy-user "${USER_NAME}:${PASS_WORD}")
        timeout 12 curl -s -o /dev/null --socks5-hostname "127.0.0.1:${PORT}" \
            "${ua[@]}" "https://${dom}" >/dev/null 2>&1
        rc_a=$?
        # 97 = 被代理拒绝；只要不是 97，就说明 ACL 放行了
        if [[ $rc_a -eq 97 ]]; then
            log_error "白名单异常：列表内的 ${dom} 反而被拒绝（rc=97）"
            log_error "  检查 $ALLOW_FILE 是否缺少 reverse true"
        else
            log_success "放行正常: ${dom}（rc=$rc_a，非 97 即 ACL 已放行）"
        fi
    fi

    local probe="whitelist-probe-$RANDOM.invalid"
    timeout 12 curl -s -o /dev/null --socks5-hostname "127.0.0.1:${PORT}" \
        --proxy-user "${USER_NAME}:${PASS_WORD}" "https://${probe}" >/dev/null 2>&1
    rc_d=$?
    if [[ $rc_d -eq 97 ]]; then
        log_success "拒绝正常: 列表外目标被拦截"
    else
        log_warn "列表外目标未被拒绝（rc=$rc_d）—— 白名单可能没生效"
    fi
}

test_proxy() {
    local rc=0
    port_listening "$PORT" || { log_error "端口 $PORT 未监听"; return 1; }
    log_success "端口 $PORT 正在监听"

    if has_cmd curl; then
        if allow_enabled; then
            # 白名单开了就不能拿 api.ipify.org 测了 —— 它多半不在列表里，
            # 被拒会造成"服务坏了"的误判。改为白名单自检。
            test_whitelist
        else
            if [[ "$USE_AUTH" == true ]]; then
                # 一律用 --proxy-user：拼进 URL 的话 @ : / 会破坏结构，
                # 而 gost 配置里存的是百分号编码后的值，客户端必须用原始明文
                timeout 15 curl -s --socks5-hostname "127.0.0.1:${PORT}" \
                    --proxy-user "${USER_NAME}:${PASS_WORD}" http://api.ipify.org >/dev/null 2>&1
            else
                timeout 15 curl -s --socks5-hostname "127.0.0.1:${PORT}" \
                    http://api.ipify.org >/dev/null 2>&1
            fi
            rc=$?
            case $rc in
                0) log_success "本机经代理出网正常" ;;
                5|6) log_error "认证失败（rc=$rc），检查用户名密码" ;;
                7)  log_error "本机连不上端口（rc=7），服务没在监听" ;;
                28) log_error "代理出网超时（rc=28）：能进代理，但代理连不到目标" ;;
                *)  log_warn "本机经代理出网未通过（rc=$rc）" ;;
            esac
        fi
    else
        log_info "curl 未安装，跳过出网测试"
    fi

    # 第二跳：公网 IP 再连一次。只测 127.0.0.1 发现不了云安全组
    if [[ -n "$SERVER_IP" && "$SERVER_IP" != "0.0.0.0" && "$SERVER_IP" != "127.0.0.1" ]]; then
        if tcp_probe "$SERVER_IP" "$PORT"; then
            log_success "公网 ${SERVER_IP}:${PORT} 可建立 TCP 连接"
        else
            log_error "公网 ${SERVER_IP}:${PORT} 连不上"
            log_error "  本机通、公网不通 = 云安全组或上游防火墙，脚本管不到"
            echo "  控制台放行: 入方向 TCP ${PORT}"
        fi
    fi
    return 0
}

# ============================================================
#  交互
# ============================================================
# 端口被占用时，说清楚是谁占的、怎么让开
port_conflict_report() {
    local p="$1" line
    line=$(port_listeners "$p" | head -n1)
    log_error "端口 $p 已被占用："
    [[ -n "$line" ]] && printf '  %s\n' "$line"
    case "$line" in
        *danted*)
            log_error "  占用者是 dante 版 SOCKS5（另一个脚本装的），先卸载它："
            echo "    systemctl disable --now danted socks5-shaping 2>/dev/null"
            echo "    pkill -9 -x danted"
            echo "    ss -ltnp | grep -w $p      # 确认没输出"
            echo "    systemctl reset-failed gost"
            ;;
        *gost*)
            log_error "  是本脚本自己的服务在跑，重启即可，不必换端口"
            ;;
        *)
            echo "  换一个端口，或先停掉占用它的服务"
            ;;
    esac
}

# 交互模式下如果占用者是 danted，直接问要不要停掉
offer_free_port() {
    local p="$1" line c
    line=$(port_listeners "$p" | head -n1)
    printf '%s' "$line" | grep -q danted || return 1
    read -r -p "  占用者是 dante 服务，现在停掉它并继续？[y/N]: " c
    [[ "${c,,}" != "y" ]] && return 1
    systemctl disable --now danted >/dev/null 2>&1
    systemctl disable --now socks5-shaping >/dev/null 2>&1
    pkill -x danted >/dev/null 2>&1
    sleep 1
    pkill -9 -x danted >/dev/null 2>&1
    sleep 1
    port_in_use "$p" && return 1
    log_success "已释放端口 $p"
    return 0
}

ask_port() {
    local def="${1:-8443}" input
    while true; do
        read -r -p "SOCKS 端口 [默认 ${def}]: " input
        input="${input:-$def}"
        if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 || "$input" -gt 65535 ]]; then
            log_error "端口必须是 1-65535"
            continue
        fi
        if port_in_use "$input"; then
            if [[ "$input" == "${PORT:-}" ]] && gost_running; then
                PORT="$input"; return 0
            fi
            log_error "端口 $input 已被占用"
            port_listeners "$input" | head -n1
            if offer_free_port "$input"; then
                PORT="$input"; return 0
            fi
            continue
        fi
        PORT="$input"; return 0
    done
}

ask_auth() {
    local m u p
    echo
    echo -e "${YELLOW}认证方式：${NC}"
    echo "  1) 用户名密码  (推荐)"
    echo "  2) 无认证      (仅限内网)"
    read -r -p "请选择 [默认 1]: " m
    m="${m:-1}"

    if [[ "$m" == "2" ]]; then
        echo
        echo -e "${RED}无认证代理一旦公网可达，通常几分钟内就会被扫描器收录：${NC}"
        echo -e "${RED}  然后陌生人的流量会把带宽和连接数吃满，${NC}"
        echo -e "${RED}  表现就是「刚搭建能用几秒，之后自己反而连不上」。${NC}"
        echo -e "  只在内网、或已用安全组限制来源 IP 时才选这个。"
        echo -n "确认使用无认证模式？[y/N]: "
        read -r c
        [[ "${c,,}" != "y" ]] && { ask_auth; return; }
        USE_AUTH=false; USER_NAME=""; PASS_WORD=""
        log_warn "已选择无认证"
        return 0
    fi

    USE_AUTH=true
    while true; do
        read -r -p "用户名（必填，字符不限，含中文也行）: " u
        USER_NAME="$u"
        if [[ -z "$USER_NAME" ]]; then
            log_error "用户名不能为空"
            continue
        fi
        valid_user_name "$USER_NAME" && break
        log_error "用户名太长（上限 64）或含换行等控制字符"
    done
    while true; do
        IFS= read -r -s -p "密码 [留空自动生成，字符不限]: " p
        echo
        if [[ -z "$p" ]]; then
            p=$(gen_pass)
            log_info "已自动生成密码: $p"
        fi
        PASS_WORD="$p"
        valid_password "$PASS_WORD" && break
        log_error "密码太长（上限 128）或含换行等控制字符"
    done
    return 0
}

# ============================================================
#  业务
# ============================================================
do_install() {
    local old_port=""
    echo
    if gost_installed; then
        load_install_info && old_port="$PORT"
        log_warn "检测到已安装（端口 ${old_port:-未知}），将覆盖配置"
        read -r -p "继续？[y/N]: " c
        [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }
    fi

    detect_os
    log_step "检查依赖"
    has_cmd curl || pkg_install curl
    has_cmd curl || die "缺少 curl"
    has_cmd tc || pkg_install iproute2 2>/dev/null || pkg_install iproute 2>/dev/null || true

    INTERFACE=$(get_iface)
    [[ -z "$INTERFACE" ]] && die "无法探测出口网卡"
    log_info "出口网卡: $INTERFACE"
    SERVER_IP=$(get_public_ip)
    log_info "公网 IP: $SERVER_IP"

    ask_port "${PORT:-8443}"
    ask_auth

    if [[ -x "$GOST_BIN" ]]; then
        log_info "已存在 $GOST_BIN，跳过下载（如需重装: rm -f $GOST_BIN）"
    else
        download_gost
    fi

    write_gost_conf
    write_unit
    write_logrotate
    open_port "$PORT"
    if [[ -n "$old_port" && "$old_port" != "$PORT" ]]; then
        close_port "$old_port"
    fi
    install_self
    write_shaping_unit
    save_install_info

    log_step "启动服务"
    stop_gost_clean
    systemctl enable gost >/dev/null 2>&1
    if ! start_gost; then
        dump_failure
        return 1
    fi

    test_proxy
    show_install_complete
    log_usage "installed port=$PORT auth=$USE_AUTH"
}

show_install_complete() {
    echo
    hr
    log_success "SOCKS5 安装完成（gost v$GOST_VER）"
    hr
    echo -e "服务器:  ${GREEN}${SERVER_IP}${NC}"
    echo -e "端口:    ${GREEN}${PORT}${NC}"
    if [[ "$USE_AUTH" == true ]]; then
        echo -e "用户名:  ${GREEN}${USER_NAME}${NC}"
        echo -e "密码:    ${GREEN}${PASS_WORD}${NC}"
        echo -e "测试:    ${YELLOW}curl --socks5-hostname ${SERVER_IP}:${PORT} --proxy-user '${USER_NAME}:${PASS_WORD}' https://api.ipify.org${NC}"
    else
        echo -e "认证:    ${RED}无认证${NC}"
        echo -e "测试:    ${YELLOW}curl --socks5-hostname ${SERVER_IP}:${PORT} https://api.ipify.org${NC}"
    fi
    echo
    echo -e "管理:  ${YELLOW}socks5${NC}      服务: ${YELLOW}systemctl {start|stop|restart|status} gost${NC}"
    hr
}

do_modify() {
    gost_installed || { log_error "尚未安装"; return 1; }
    load_install_info || log_warn "安装信息缺失"
    PORT="${PORT:-8443}"
    INTERFACE="${INTERFACE:-$(get_iface)}"

    echo
    echo -e "${CYAN}当前配置${NC}"
    hr
    echo "  端口:  $PORT"
    echo "  认证:  $([[ "$USE_AUTH" == true ]] && echo "用户名密码 ($USER_NAME)" || echo "无认证")"
    echo "  限速:  $(limit_status_text)"
    hr
    echo "  1) 改端口"
    echo "  2) 改用户名密码"
    echo "  3) 切换认证模式"
    echo "  4) 完全重新配置"
    echo "  0) 返回"
    echo
    local ch c
    read -r -p "请选择: " ch

    case "$ch" in
        1)
            local old="$PORT" newp
            ask_port "$old"
            newp="$PORT"
            [[ "$newp" == "$old" ]] && { log_info "端口未变化"; return 0; }
            retune_port "$old" "$newp" && log_success "端口已从 $old 改为 $PORT" \
                || log_error "配置已改但服务未正常启动"
            ;;
        2)
            ask_auth
            write_gost_conf; save_install_info
            restart_gost && log_success "认证信息已更新"
            ;;
        3)
            if [[ "$USE_AUTH" == true ]]; then
                read -r -p "确认关闭认证？[y/N]: " c
                [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }
                USE_AUTH=false; USER_NAME=""; PASS_WORD=""
            else
                read -r -p "确认开启认证？[y/N]: " c
                [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }
                ask_auth
            fi
            write_gost_conf; save_install_info
            restart_gost && log_success "认证模式已切换"
            ;;
        4)
            local old4="$PORT"
            ask_port "$old4"; ask_auth
            if [[ "$PORT" != "$old4" ]]; then
                retune_port "$old4" "$PORT" && log_success "配置已更新"
            else
                write_gost_conf; open_port "$PORT"; save_install_info
                restart_gost && log_success "配置已更新"
            fi
            ;;
        0) return 0 ;;
        *) log_error "无效选择" ;;
    esac
    log_usage "config modified ($ch)"
}

retune_port() {
    local old="$1" new="$2"
    PORT="$new"
    write_gost_conf
    open_port "$new"
    close_port "$old"
    save_install_info
    load_limit_conf
    if [[ -n "$LIMIT_DOWN$LIMIT_UP" ]]; then
        LIMIT_PORT="$new"; LIMIT_IFACE="${LIMIT_IFACE:-$(get_iface)}"
        save_limit_conf; write_shaping_helper
        systemctl try-restart gost-shaping >/dev/null 2>&1
        log_info "限速规则已跟随端口更新"
    fi
    restart_gost
}

do_uninstall() {
    if ! gost_installed && [[ ! -f "$GOST_CONF" ]]; then
        log_warn "未检测到 gost 服务"
        return 0
    fi
    load_install_info
    echo
    log_warn "即将卸载 gost SOCKS5（端口 ${PORT:-?}）"
    read -r -p "确认卸载？[y/N]: " c
    [[ "${c,,}" != "y" ]] && { log_info "已取消"; return 0; }

    log_step "停止服务"
    systemctl disable --now gost-shaping >/dev/null 2>&1
    systemctl disable gost >/dev/null 2>&1
    stop_gost_clean

    log_step "清理限速"
    shaping_clear "$(get_iface)"
    rm -f "$SHAPING_UNIT" "$LIMIT_CONF" "$SHAPING_HELPER"

    log_step "删除单元与配置"
    rm -f "$UNIT" "$GOST_CONF" "$LOGROTATE_FILE"
    systemctl daemon-reload

    read -r -p "删除 gost 二进制 $GOST_BIN？[y/N]: " c
    if [[ "${c,,}" == "y" ]]; then rm -f "$GOST_BIN"; log_info "二进制已删除"; else log_info "二进制已保留"; fi

    if [[ -n "$PORT" ]]; then
        read -r -p "移除防火墙放行（端口 $PORT）？[y/N]: " c
        if [[ "${c,,}" == "y" ]]; then close_port "$PORT"; else log_info "防火墙规则已保留"; fi
    fi

    read -r -p "删除日志 $LOG_FILE 与统计数据？[y/N]: " c
    if [[ "${c,,}" == "y" ]]; then rm -f "$LOG_FILE"; else log_info "日志已保留"; fi

    read -r -p "删除管理信息与 $SELF_PATH？[y/N]: " c
    if [[ "${c,,}" == "y" ]]; then rm -rf "$CONFIG_DIR"; rm -f "$SELF_PATH"; log_info "管理文件已清理"
    else log_info "管理文件已保留"; fi

    hr
    log_success "卸载完成"
    log_usage "uninstalled"
}

do_limit() {
    gost_installed || { log_error "尚未安装"; return 1; }
    load_install_info
    PORT="${PORT:-8443}"
    load_limit_conf
    LIMIT_IFACE=$(get_iface)
    [[ -z "$LIMIT_IFACE" ]] && { log_error "无法确定出口网卡"; return 1; }
    [[ -z "$LIMIT_PORT" ]] && LIMIT_PORT="$PORT"

    while true; do
        echo
        echo -e "${BLUE}端口限速${NC}  (端口 ${PORT}, 网卡 ${LIMIT_IFACE})"
        hr
        echo "  当前: $(limit_status_text)"
        hr
        echo "  1) 同时限制下载和上传"
        echo "  2) 只限制下载（服务器 → 客户端）"
        echo "  3) 只限制上传（客户端 → 服务器）"
        echo "  4) 查看 tc 实况"
        echo "  5) 清除限速"
        echo "  0) 返回"
        echo
        local ch v
        read -r -p "请选择: " ch
        case "$ch" in
            1|2|3)
                echo
                echo "单位: 10 = 10Mbps, 800K = 800Kbps, 0 = 不限"
                local nd="" nu=""
                while true; do
                    if [[ "$ch" == "1" || "$ch" == "2" ]]; then
                        read -r -p "下载速率: " v; nd=$(rate_norm "$v") || continue
                    fi
                    if [[ "$ch" == "1" || "$ch" == "3" ]]; then
                        read -r -p "上传速率: " v; nu=$(rate_norm "$v") || continue
                    fi
                    break
                done
                LIMIT_DOWN="$nd"; LIMIT_UP="$nu"
                LIMIT_IFACE=$(get_iface)
                [[ -z "$LIMIT_IFACE" ]] && { log_error "网卡探测失败"; return 1; }
                LIMIT_PORT="$PORT"
                save_limit_conf
                log_step "应用 tc 规则"
                if shaping_apply "$LIMIT_IFACE" "$LIMIT_PORT" "$LIMIT_DOWN" "$LIMIT_UP"; then
                    log_success "限速已生效: $(limit_status_text)"
                else
                    log_error "限速应用失败"
                fi
                write_shaping_unit
                systemctl enable gost-shaping >/dev/null 2>&1
                systemctl restart gost-shaping >/dev/null 2>&1
                log_info "已设置开机自动恢复"
                log_usage "limit set down=${LIMIT_DOWN:-none} up=${LIMIT_UP:-none}"
                return 0
                ;;
            4)
                has_cmd tc || { log_error "缺少 tc"; continue; }
                echo; echo -e "${CYAN}qdisc:${NC}";  tc qdisc show dev "$LIMIT_IFACE" 2>/dev/null
                echo; echo -e "${CYAN}class:${NC}";  tc class show dev "$LIMIT_IFACE" 2>/dev/null
                echo; echo -e "${CYAN}filter:${NC}"; tc filter show dev "$LIMIT_IFACE" parent 1: 2>/dev/null
                if [[ -n "$LIMIT_UP" ]]; then
                    echo; echo -e "${CYAN}ingress/$IFB_DEV:${NC}"
                    tc filter show dev "$LIMIT_IFACE" parent ffff: 2>/dev/null
                    tc class show dev "$IFB_DEV" 2>/dev/null
                fi
                ;;
            5)
                shaping_clear "$(get_iface)"
                LIMIT_DOWN=""; LIMIT_UP=""; LIMIT_PORT="$PORT"; LIMIT_IFACE=$(get_iface)
                save_limit_conf
                systemctl disable --now gost-shaping >/dev/null 2>&1
                log_success "限速已清除"
                log_usage "limit cleared"
                ;;
            0) return 0 ;;
            *) log_error "无效选择" ;;
        esac
    done
}

# ---------- 查看 ----------
show_status() {
    echo
    echo -e "${BLUE}gost SOCKS5 状态${NC}"
    hr
    if ! gost_installed; then log_warn "未安装"; return 0; fi
    gost_running && echo -e "运行状态: ${GREEN}运行中${NC}" || echo -e "运行状态: ${RED}已停止${NC}"
    systemctl is-enabled --quiet gost 2>/dev/null \
        && echo -e "开机自启: ${GREEN}已启用${NC}" || echo -e "开机自启: ${RED}已禁用${NC}"

    load_install_info
    PORT="${PORT:-8443}"
    echo
    echo -e "${CYAN}配置${NC}"
    echo "  公网 IP:  ${SERVER_IP:-未知}"
    echo "  端口:     $PORT"
    echo "  网卡:     ${INTERFACE:-未知}"
    echo "  认证:     $([[ "$USE_AUTH" == true ]] && echo "用户名密码 (${USER_NAME})" || echo "无认证")"
    echo "  安装时间: ${INSTALL_DATE:-未知}"
    port_listening "$PORT" && echo -e "  端口监听: ${GREEN}正常${NC}" || echo -e "  端口监听: ${RED}异常${NC}"
    echo "  限速:     $(limit_status_text)"
    echo
    echo -e "${CYAN}进程${NC}"
    local pl
    pl=$(ps -eo %mem,%cpu,comm 2>/dev/null | awk '$3 ~ /^gost/' | head -n1)
    [[ -n "$pl" ]] && echo "  内存: $(echo "$pl" | awk '{print $1}')%   CPU: $(echo "$pl" | awk '{print $2}')%" || echo "  进程未运行"
    echo "  重启次数: $(systemctl show gost -p NRestarts --value 2>/dev/null)"
    log_usage "status checked"
}

show_info() {
    echo
    echo -e "${BLUE}连接信息${NC}"
    hr
    load_install_info || { log_error "未找到安装信息"; return 1; }
    echo -e "服务器:  ${GREEN}${SERVER_IP}${NC}"
    echo -e "端口:    ${GREEN}${PORT}${NC}"
    if [[ "$USE_AUTH" == true ]]; then
        echo -e "用户名:  ${GREEN}${USER_NAME}${NC}"
        echo -e "密码:    ${GREEN}${PASS_WORD}${NC}"
    else
        echo -e "认证:    ${RED}无认证${NC}"
    fi
    echo
    echo -e "${CYAN}客户端${NC}"
    if [[ "$USE_AUTH" == true ]]; then
        echo "  curl:   curl --socks5-hostname ${SERVER_IP}:${PORT} --proxy-user $(printf '%q' "${USER_NAME}:${PASS_WORD}") https://api.ipify.org"
    else
        echo "  curl:   curl --socks5-hostname ${SERVER_IP}:${PORT} https://api.ipify.org"
    fi
    echo "  浏览器: SOCKS5  ${SERVER_IP}  ${PORT}  （勾选「代理解析域名 / 远程 DNS」）"
    log_usage "info viewed"
}

show_logs() {
    echo -e "${CYAN}日志（Ctrl+C 退出）${NC}"
    journalctl -u gost -f
}

do_doctor() {
    local self="${BASH_SOURCE[0]:-$0}"
    local ok="${GREEN}OK${NC}" bad="${RED}FAIL${NC}" na="${YELLOW}--${NC}"
    echo
    echo -e "${BLUE}socks5(gost) 自检${NC}"
    hr

    echo -e "${CYAN}[脚本]${NC}"
    echo "  运行位置: $self"
    echo "  运行版本: v$SCRIPT_VERSION"
    [[ -f "$self" ]] && { bash -n "$self" 2>/dev/null && echo -e "  语法自检: $ok" || echo -e "  语法自检: $bad"; }
    [[ -x "$SELF_PATH" ]] && echo "  已装命令: $SELF_PATH" || echo -e "  已装命令: $bad 缺失"
    local iv; iv=$(info_version); [[ -n "$iv" ]] && echo "  安装记录: v$iv"

    echo
    echo -e "${CYAN}[程序与服务]${NC}"
    if [[ -x "$GOST_BIN" ]]; then
        echo "  gost:     $("$GOST_BIN" -V 2>/dev/null | head -n1)"
    else
        echo -e "  gost:     $bad 未安装（$GOST_BIN）"
    fi
    if gost_installed; then
        gost_running && echo -e "  服务:     $ok 运行中" || echo -e "  服务:     $bad 未运行"
        local since nr up
        since=$(systemctl show gost -p ActiveEnterTimestamp --value 2>/dev/null)
        nr=$(systemctl show gost -p NRestarts --value 2>/dev/null)
        if [[ -n "$since" ]]; then
            up=$(date -d "$since" +%s 2>/dev/null)
            [[ -n "$up" ]] && echo "  启动于:   $since （已运行 $(( $(date +%s) - up )) 秒）" || echo "  启动于:   $since"
        fi
        echo "  重启次数: ${nr:-0}"
        [[ -n "$nr" && "$nr" =~ ^[0-9]+$ && "$nr" -gt 2 ]] && echo -e "  ${YELLOW}重启偏多 → 进程在反复退出${NC}"
        echo "  最近日志:"
        journalctl -u gost --no-pager -n 8 2>/dev/null | sed 's/^/    /'
    fi

    echo
    echo -e "${CYAN}[配置]${NC}"
    if [[ -f "$GOST_CONF" ]]; then
        local perm
        perm=$(stat -c '%a' "$GOST_CONF" 2>/dev/null)
        echo "  $GOST_CONF  权限=${perm:-未知}"
        [[ "$perm" == "600" ]] && echo -e "  凭据写权限: $ok" || echo -e "  凭据写权限: ${YELLOW}建议 600（chmod 600 $GOST_CONF）${NC}"
    else
        echo -e "  $GOST_CONF: $na 不存在"
    fi
    if [[ -f "$UNIT" ]]; then
        echo "  unit:     $(grep -E '^Type=|^Restart=' "$UNIT" 2>/dev/null | tr '\n' ' ')"
        grep -q -- '-C ' "$UNIT" 2>/dev/null && echo -e "  凭据位置: $ok （在配置文件里，不在命令行）" \
            || echo -e "  凭据位置: ${YELLOW}命令行里可能含密码，建议改用 -C 配置文件${NC}"
    fi

    echo
    echo -e "${CYAN}[端口与可达性]${NC}"
    local dport=""
    if load_install_info; then
        dport="$PORT"
        echo "  SOCKS 端口: $dport"
        port_listening "$dport" && echo -e "  监听状态: $ok" || echo -e "  监听状态: $bad 未监听"
        has_cmd ss && echo "  绑定地址: $(ss -H -ltn 2>/dev/null | awk -v w=":$dport" '$4 ~ (w "$") {print $4}' | sort -u | tr '\n' ' ')"
        local local_ok=0
        tcp_probe 127.0.0.1 "$dport" && { local_ok=1; echo -e "  本机探测: $ok"; } || echo -e "  本机探测: $bad"
        if [[ -n "$SERVER_IP" && "$SERVER_IP" != "0.0.0.0" && "$SERVER_IP" != "127.0.0.1" ]]; then
            if tcp_probe "$SERVER_IP" "$dport"; then
                echo -e "  公网探测: $ok"
            else
                echo -e "  公网探测: $bad"
                [[ $local_ok -eq 1 ]] \
                    && echo -e "  ${YELLOW}本机通公网不通 → 云安全组/上游防火墙，去控制台放行 TCP $dport${NC}" \
                    || echo -e "  ${YELLOW}本机也不通，先解决服务监听${NC}"
            fi
        fi
    else
        echo -e "  安装信息: $na 缺失"
    fi
    echo "  限速: $(limit_status_text)"

    echo
    echo -e "${CYAN}[目标白名单]${NC}"
    allow_init
    if allow_enabled; then
        echo -e "  状态:     $ok 已启用（$(allow_count) 条规则）"
        local i=1 r
        while IFS= read -r r; do
            printf '    %2d) %s\n' "$i" "$r"
            i=$((i + 1))
            [[ $i -gt 12 ]] && { echo "    ...（更多见 $ALLOW_FILE）"; break; }
        done < <(allow_rules)
        echo "  配置文件: $ALLOW_FILE"
        grep -q '^reverse' "$ALLOW_FILE" 2>/dev/null \
            && echo -e "  reverse:  $ok （白名单语义；文件方式下 ~ 前缀会被忽略，必须靠这行）" \
            || echo -e "  reverse:  $bad 缺少 reverse true，当前会被当成黑名单！"
    else
        echo -e "  状态:     ${YELLOW}未启用（放行任意目标）${NC}"
        [[ -f "$ALLOW_FILE" ]] && echo "  配置文件: $ALLOW_FILE"
    fi

    echo
    echo -e "${CYAN}[滥用风险]${NC}"
    if load_install_info; then
        if [[ "$USE_AUTH" != true ]]; then
            echo -e "  认证:     ${RED}未启用${NC}"
            echo -e "  ${RED}无认证 + 公网可达 = 数分钟内被扫描器收录，成为开放代理${NC}"
            echo "  典型表现：刚搭建能用几秒，随后自己的连接反而超时（带宽被白嫖流量挤占）"
        else
            echo -e "  认证:     $ok 已启用（${USER_NAME}）"
        fi
        if has_cmd ss; then
            local cn
            cn=$(ss -Htn state established 2>/dev/null | awk -v w=":$PORT" '$4 ~ (w "$")' | wc -l)
            echo "  当前连接: ${cn:-0}"
            if [[ "${cn:-0}" -gt 20 && "$USE_AUTH" != true ]]; then
                echo -e "  ${RED}连接数异常偏高，很可能正在被他人使用${NC}"
            fi
        fi
        # 近 10 分钟出现过的客户端 IP 数量，用于判断是否被外部滥用
        if has_cmd journalctl; then
            local ips
            ips=$(journalctl -u gost --since '-10 min' --no-pager 2>/dev/null \
                | grep -oE '\[socks5\] [0-9]{1,3}(\.[0-9]{1,3}){3}' \
                | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u | wc -l)
            echo "  近10分钟客户端IP数: ${ips:-0}"
            [[ "${ips:-0}" -gt 3 ]] && echo -e "  ${YELLOW}IP 数偏多，正常自用通常 1-2 个${NC}"
        fi
    else
        echo -e "  安装信息: $na 缺失"
    fi

    echo
    echo -e "${CYAN}[防火墙]${NC}"
    local fw=0
    if has_cmd ufw; then
        fw=1
        echo "  ufw: $(ufw status 2>/dev/null | head -n1 | sed 's/^Status: //')"
        ufw status 2>/dev/null | grep -E "^${dport}/tcp" | head -n2 | sed 's/^/    /'
    fi
    if has_cmd firewall-cmd; then
        fw=1
        local fs; fs=$(firewall-cmd --state 2>/dev/null)
        echo "  firewalld: ${fs:-未运行}"
        [[ "$fs" == "running" ]] && echo "    已放行: $(firewall-cmd --list-ports 2>/dev/null | tr ' ' '\n' | grep -E "^${dport}/" | tr '\n' ' ')"
    fi
    if has_cmd iptables; then
        fw=1
        echo "  iptables 匹配 ${dport} 规则: $(iptables -S INPUT 2>/dev/null | grep -c -- "--dport ${dport}") 条"
    fi
    [[ $fw -eq 0 ]] && echo -e "  $na 未检测到防火墙工具"
    echo -e "  ${YELLOW}系统防火墙放行 ≠ 云安全组放行，两者都要开${NC}"

    # dante 版会创建系统账号做 PAM 认证，gost 不需要；留着只是垃圾
    local lu
    for lu in socksuser; do
        if id "$lu" >/dev/null 2>&1; then
            echo
            echo -e "  ${YELLOW}发现 dante 版遗留的系统账号: $lu（gost 不需要）${NC}"
            echo "    删除: userdel $lu"
        fi
    done
    hr
    return 0
}

show_version() {
    echo "socks5 (gost) 管理脚本 v$SCRIPT_VERSION"
    echo "运行位置: ${BASH_SOURCE[0]:-$0}"
    [[ -x "$SELF_PATH" ]] && echo "已安装命令: $SELF_PATH" || echo "已安装命令: 无"
    [[ -x "$GOST_BIN" ]] && echo "gost: $("$GOST_BIN" -V 2>/dev/null | head -n1)"
    local iv; iv=$(info_version); [[ -n "$iv" ]] && echo "安装记录版本: v$iv"
    return 0
}

show_stats() {
    echo
    echo -e "${BLUE}操作统计${NC}"
    hr
    [[ -f "$STATS_FILE" ]] || { log_warn "暂无记录"; return 0; }
    tail -n 10 "$STATS_FILE"
    echo
    echo "  总操作:   $(wc -l <"$STATS_FILE")"
    echo "  安装:     $(count_in 'installed' "$STATS_FILE")"
    echo "  卸载:     $(count_in 'uninstalled' "$STATS_FILE")"
    echo "  重启:     $(count_in 'service restarted' "$STATS_FILE")"
    echo "  限速变更: $(count_in 'limit ' "$STATS_FILE")"
}

# ---------- 自安装 ----------
install_self() {
    if [[ -f "$0" ]] && [[ "$(readlink -f "$0" 2>/dev/null)" == "$(readlink -f "$SELF_PATH" 2>/dev/null)" ]]; then
        return 0
    fi
    local got=""
    if [[ -f "$0" && -r "$0" ]]; then
        mkdir -p "$(dirname "$SELF_PATH")" 2>/dev/null
        install -m 0755 "$0" "$SELF_PATH" 2>/dev/null && got="local"
    fi
    if [[ -z "$got" ]] && has_cmd curl; then
        # bash <(curl ...) 时 $0 是管道，只能重新拉一份
        local tmp
        tmp=$(mktemp /tmp/socks5g.XXXXXX 2>/dev/null) || return 0
        if curl -fsSL --max-time 25 -H 'Accept: application/vnd.github.raw' "$SELF_API_URL" -o "$tmp" 2>/dev/null \
            || curl -fsSL --max-time 25 "$SELF_URL" -o "$tmp" 2>/dev/null; then
            if head -n1 "$tmp" 2>/dev/null | grep -q '^#!.*bash' && grep -q 'SCRIPT_VERSION=' "$tmp" 2>/dev/null; then
                install -m 0755 "$tmp" "$SELF_PATH" 2>/dev/null && got="download"
            fi
        fi
        rm -f "$tmp" 2>/dev/null
    fi
    [[ -n "$got" ]] && log_info "管理命令已安装: $SELF_PATH"
    return 0
}

# ============================================================
#  菜单与入口
# ============================================================
show_menu() {
    load_install_info >/dev/null 2>&1 || true
    local state
    if gost_installed; then
        gost_running && state="${GREEN}运行中${NC}  端口 ${PORT:-?}" || state="${RED}已停止${NC}  端口 ${PORT:-?}"
    else
        state="${YELLOW}未安装${NC}"
    fi
    echo
    echo "=================================================="
    echo -e "  ${BOLD}SOCKS5 管理脚本 v${SCRIPT_VERSION}${NC}  (gost ${GOST_VER})"
    echo -e "  状态: ${state}"
    echo -e "  限速: $(limit_status_text)"
    echo -e "  白名单: $(allow_status_text)"
    echo "=================================================="
    echo -e "  ${CYAN}1${NC}) 安装 SOCKS5"
    echo -e "  ${CYAN}2${NC}) 修改配置（端口 / 认证）"
    echo -e "  ${CYAN}3${NC}) 卸载"
    echo -e "  ${CYAN}4${NC}) 设置限速"
    echo -e "  ${CYAN}w${NC}) 白名单（只放行指定域名）"
    echo "  ------------------------------"
    echo -e "  ${CYAN}5${NC}) 查看状态"
    echo -e "  ${CYAN}6${NC}) 查看连接信息"
    echo -e "  ${CYAN}7${NC}) 重启服务"
    echo -e "  ${CYAN}8${NC}) 实时日志"
    echo -e "  ${CYAN}9${NC}) 自检 (doctor)"
    echo -e "  ${CYAN}0${NC}) 退出"
    echo
}

handle_menu() {
    while true; do
        show_menu
        read -r -p "请选择 [0-9/w]: " choice
        case "$choice" in
            1) do_install ;;
            2) do_modify ;;
            3) do_uninstall ;;
            4) do_limit ;;
            w|W|allow) do_allow ;;
            5) show_status ;;
            6) show_info ;;
            7) load_install_info; restart_gost ;;
            8) show_logs ;;
            9) do_doctor ;;
            0) log_info "已退出"; log_usage "exit"; exit 0 ;;
            *) log_error "无效选项，请输入 0-9 或 w" ;;
        esac
        echo
        read -r -p "按回车继续..." -r _
    done
}

show_help() {
    cat <<EOF
SOCKS5 管理脚本 v${SCRIPT_VERSION}（gost ${GOST_VER} 后端）

用法: $0 [命令] [选项]

命令:
  install, -i          安装（非交互: --port N --user U --pass P --allow 域名列表 --no-auth）
  modify, -m           修改配置
  uninstall, -u        卸载
  limit, -L            设置端口限速
  status, -s           查看状态
  info                 连接信息
  restart, -r          重启服务
  logs, -l             实时日志
  allow                白名单管理（只放行指定域名）
  doctor               自检
  stats                操作统计
  version              版本
  help, -h             本帮助

示例:
  $0 install --port 8443 --user u1 --pass 'p@ss:w/rd'
  $0 doctor
  $0
EOF
}

do_install_cli() {
    shift
    local wp="" wu="" wpp="" noauth=0 wallow=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port) wp="$2"; shift 2 ;;
            --user) wu="$2"; shift 2 ;;
            --pass) wpp="$2"; shift 2 ;;
            --allow) wallow="$2"; shift 2 ;;
            --no-auth) noauth=1; shift ;;
            *) die "未知选项: $1" ;;
        esac
    done

    detect_os
    has_cmd curl || pkg_install curl
    has_cmd curl || die "缺少 curl"
    INTERFACE=$(get_iface)
    [[ -z "$INTERFACE" ]] && die "无法探测网卡"
    SERVER_IP=$(get_public_ip)

    PORT="${wp:-8443}"
    [[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "端口非法: $PORT"

    # 非交互模式没法询问，端口被占就直接中止，且不在磁盘上留下半成品
    if port_in_use "$PORT"; then
        if port_listeners "$PORT" | grep -q gost; then
            log_warn "端口 $PORT 由现有的 gost 服务占用，将继续并重启它"
        else
            echo
            port_conflict_report "$PORT"
            die "端口 $PORT 被占用，安装中止（未做任何改动）"
        fi
    fi
    if [[ "$noauth" == "1" ]]; then
        USE_AUTH=false; USER_NAME=""; PASS_WORD=""
    else
        USE_AUTH=true
        # 没给 --user 就随机生成，不再用固定的 socksuser
        USER_NAME="${wu:-$(gen_user)}"
        PASS_WORD="${wpp:-$(gen_pass)}"
        valid_user_name "$USER_NAME" || die "用户名太长（上限 64）或含控制字符"
        valid_password "$PASS_WORD" || die "密码太长（上限 128）或含控制字符"
        [[ -z "$wu" ]] && log_info "未指定 --user，已生成用户名: $USER_NAME"
        [[ -z "$wpp" ]] && log_info "未指定 --pass，已生成密码: $PASS_WORD"
    fi

    # 白名单：命令行给了就写入（逗号或空格分隔）
    allow_init
    if [[ -n "$wallow" ]]; then
        wallow="${wallow//,/ }"
        # shellcheck disable=SC2086
        allow_add $wallow >/dev/null
        log_info "白名单: $(allow_status_text)"
    fi

    [[ -x "$GOST_BIN" ]] || download_gost
    write_gost_conf
    write_unit
    write_logrotate
    open_port "$PORT"
    install_self
    write_shaping_unit
    save_install_info

    stop_gost_clean
    systemctl enable gost >/dev/null 2>&1
    if ! start_gost; then
        dump_failure
        exit 1
    fi
    test_proxy
    show_install_complete
    log_usage "installed port=$PORT auth=$USE_AUTH (cli)"
}

main() {
    need_root

    case "${1:-}" in
        _apply-limit) limit_apply_from_conf; exit 0 ;;
        _clear-limit) shaping_clear "$(get_iface)"; exit 0 ;;
    esac

    mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
    log_usage "run: ${*:-menu}"
    [[ -x "$SELF_PATH" ]] || install_self

    case "${1:-}" in
        "")                        handle_menu ;;
        install|--install|-i)      do_install_cli "$@" ;;
        modify|--modify|-m)        do_modify ;;
        uninstall|--uninstall|-u)  do_uninstall ;;
        limit|--limit|-L)          do_limit ;;
        status|--status|-s)        show_status ;;
        info|--info)               show_info ;;
        restart|--restart|-r)      load_install_info; restart_gost ;;
        logs|--logs|-l)            show_logs ;;
        allow|--allow)             do_allow ;;
        doctor|--doctor)           do_doctor ;;
        stats|--stats)             show_stats ;;
        version|--version)         show_version ;;
        help|--help|-h)            show_help ;;
        *) log_error "未知命令: $1"; show_help; exit 1 ;;
    esac
}

trap 'echo; log_info "已中断"; exit 130' INT TERM

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
