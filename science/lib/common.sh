# shellcheck shell=bash
#
# science/lib/common.sh —— 被 install.sh source，不单独执行。
#
# 这里只放三类东西：
#   1. 日志与交互（不打印任何密钥值）
#   2. 只读探测与参数校验
#   3. 对 HAO 三个脚本（guard / secret / state）的包装
#
# 凡是「生成/复用凭据」「写状态」「判归属」三件事，都不在这里自己实现 ——
# 见仓库根 AGENTS.md：那三件事只能走 skills/hao-deploy/scripts/ 下的脚本，
# 否则交接契约和「密钥不进对话」的保证就废了。

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $*" >&2; }
log_step()    { echo -e "${BOLD}${CYAN}[STEP]${NC} $*" >&2; }
log_success() { echo -e "${GREEN}[OK]${NC} $*" >&2; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die() {
    log_error "$*"
    exit 1
}

# ==================== 路径 ====================
# 主机上的路径一律用通用形式（无 hao- 前缀），和仓库其余模块一致：
# 不知道这套工具存在的运维也应该能维护出来的结果。
SCIENCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$SCIENCE_DIR/templates"

XRAY_BIN="/usr/local/bin/xray"
XRAY_ETC="/usr/local/etc/xray"
XRAY_CONF_DIR="$XRAY_ETC/conf.d"
# 下面几个常量由同级的 core.sh / manage.sh 使用。shellcheck 单文件检查看不到
# 那些引用，所以逐行标注 SC2034；它们不 export，因为只在同一个进程里共享。
# shellcheck disable=SC2034
XRAY_ASSET_DIR="/usr/local/share/xray"
# shellcheck disable=SC2034
XRAY_LOG_DIR="/var/log/xray"
# shellcheck disable=SC2034
XRAY_UNIT="/etc/systemd/system/xray.service"
# 状态记录目录。hao-state.sh 认同一个环境变量，测试时一起覆盖就行。
# shellcheck disable=SC2034
STATE_SERVICES_DIR="${HAO_STATE_DIR:-/var/lib/hao}/services"
CRED_DIR="/etc/hao"

# 三个必须走脚本的地方。HAO_SKILL_DIR 可覆盖（例如 skill 被装到别处）。
SKILL_DIR="${HAO_SKILL_DIR:-$SCIENCE_DIR/../skills/hao-deploy}"
SKILL_SCRIPTS="$SKILL_DIR/scripts"

require_skill_scripts() {
    local s
    for s in hao-guard.sh hao-secret.sh hao-state.sh; do
        [ -x "$SKILL_SCRIPTS/$s" ] || die "找不到 $SKILL_SCRIPTS/$s。这个工具依赖仓库里的那三个脚本（凭据、状态、归属判断），请在完整的仓库检出里运行，或用 HAO_SKILL_DIR 指向 skill 目录。"
    done
}

guard()  { "$SKILL_SCRIPTS/hao-guard.sh"  "$@"; }
secret() { "$SKILL_SCRIPTS/hao-secret.sh" "$@"; }
state()  { "$SKILL_SCRIPTS/hao-state.sh"  "$@"; }

cred_file() { printf '%s/%s.env' "$CRED_DIR" "$1"; }
client_file() { printf '%s/%s.client.txt' "$CRED_DIR" "$1"; }
template() { printf '%s/%s' "$TEMPLATE_DIR" "$1"; }

# ==================== 前置检查 ====================
require_root() {
    [ "$(id -u)" -eq 0 ] || die "必须用 root 运行：sudo $0 $*"
}

require_os() {
    local result
    result="$(guard os-supported)"
    case "$result" in
        *" supported") log_info "系统: $result" ;;
        *) die "不支持的系统: $result（支持 Debian 12/13、Ubuntu 22.04/24.04/26.04）。别在别的系统上硬上。" ;;
    esac
}

require_cmds() {
    local missing="" cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
    done
    [ -z "$missing" ] || die "缺少必要命令:$missing。先装上：apt-get install -y$missing"
}

is_unattended() { [ "${HAO_UNATTENDED:-}" = "1" ]; }

# 改系统之前先讲清楚再确认（只读检查不需要确认）。
# HAO_UNATTENDED=1 表示调用方（通常是 agent，已经在对话里取得过确认）自己负责。
confirm() {
    local prompt="$1" answer
    if is_unattended; then
        log_info "非交互模式，跳过确认：$prompt"
        return 0
    fi
    printf '%s [y/N]: ' "$prompt" >&2
    read -r answer
    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ==================== 探测与校验 ====================
detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "linux-64" ;;
        arm64|aarch64) echo "linux-arm64-v8a" ;;
        *)             echo "unknown" ;;
    esac
}

detect_server_ip() {
    local ip
    ip="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
        || curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
        || true)"
    [ -n "$ip" ] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    printf '%s' "$ip"
}

# 解析域名的**全部** A 记录。只取第一条会在多 A 记录（轮询）的域名上误判成
# 「和本机不一致」，白弹一次确认。
resolve_domain() {
    local domain="$1" ips=""
    # 每条都补 `|| true`：pipefail 下「没解析出结果」会让赋值本身失败，
    # 而那是需要下游判断的正常分支，不是脚本错误。
    if command -v dig >/dev/null 2>&1; then
        ips="$(dig +short +time=3 "$domain" A 2>/dev/null | grep -E '^[0-9.]+$' || true)"
    fi
    [ -n "$ips" ] || ips="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    printf '%s' "$ips"
}

# 某个 IP 是否在域名的解析结果里
domain_points_here() {
    local domain="$1" ip="$2" got
    [ -n "$ip" ] || return 1
    got="$(resolve_domain "$domain")"
    [ -n "$got" ] || return 1
    printf '%s\n' "$got" | grep -qxF "$ip"
}

validate_domain() {
    local domain="$1"
    [ -n "$domain" ] || die "域名不能为空"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]] \
        || die "域名格式不对: $domain"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
        || die "端口必须是 1-65535 的数字: $port"
}

# 代理用户名会进 JSON 配置和 Basic 认证头，限制成保守字符集：
# 引号/反斜杠会破坏 JSON，冒号会破坏 user:pass 的分隔。
validate_proxy_user() {
    local user="$1"
    [ -n "$user" ] || die "用户名不能为空"
    [[ "$user" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
        || die "用户名只允许字母、数字、点、下划线、连字符（1-64 位）: $user"
}

# ==================== 文件写入 ====================
# 原子写入：先写临时文件再 mv，避免半截文件被 xray 读到。
write_file() {
    local target="$1" mode="$2" dir tmp
    dir="$(dirname "$target")"
    [ -d "$dir" ] || mkdir -p "$dir"
    tmp="$(mktemp "${target}.tmp.XXXXXX")"
    if ! cat > "$tmp"; then
        rm -f "$tmp"
        die "写入失败: $target"
    fi
    chmod "$mode" "$tmp"
    mv "$tmp" "$target"
}

install_template() {
    local name="$1" target="$2" mode="$3"
    [ -r "$(template "$name")" ] || die "模板不存在: $(template "$name")"
    write_file "$target" "$mode" < "$(template "$name")"
    log_success "已写入 $target (mode $mode)"
}

# 把 haystack 里所有 needle 换成 value，结果放在 SUBST_OUT。
#
# 不用 ${haystack//$needle/$value}：bash 的 pattern substitution 对替换串里的 `&`
# 有特殊语义（代表刚匹配到的文本），而这个语义是后来才加进 bash 的 —— 同一份脚本
# 在不同 bash 版本上结果不一样，值里带 & 就会被静默写坏成 @@TOKEN@@。
# 这段和 hao-secret.sh 里的 hao_subst_literal 是同一个修法，两处都要在。
SUBST_OUT=""
subst_literal() {
    local haystack="$1" needle="$2" value="$3" out=""
    while [ -n "$haystack" ]; do
        case "$haystack" in
            *"$needle"*)
                out="${out}${haystack%%"$needle"*}${value}"
                haystack="${haystack#*"$needle"}"
                ;;
            *)
                out="${out}${haystack}"
                haystack=""
                ;;
        esac
    done
    SUBST_OUT="$out"
}

# 把模板里的**非密钥**占位符替换掉。密钥占位符留给 hao-secret.sh render。
render_plain() {
    local name="$1" output="$2" mode="$3"
    shift 3
    local tmpl content pair key value
    tmpl="$(template "$name")"
    [ -r "$tmpl" ] || die "模板不存在: $tmpl"
    content="$(cat "$tmpl")"
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        subst_literal "$content" "@@${key}@@" "$value"
        content="$SUBST_OUT"
    done
    SUBST_OUT=""
    printf '%s\n' "$content" | write_file "$output" "$mode"
}

# 落盘前确认没有漏掉的占位符 —— 一个没替换的 @@TOKEN@@ 会让 xray 配置直接解析失败，
# 而且报错信息指向的是行号不是原因。
# 结尾的 `|| true` 不是偷懒：pipefail 下 grep 找不到东西会让整条赋值失败，
# 而「找不到占位符」恰好是正常情况。
assert_no_tokens() {
    local file="$1" leftover
    leftover="$(grep -oE '@@[A-Z][A-Z0-9_]*@@' "$file" 2>/dev/null | sort -u | tr '\n' ' ' || true)"
    [ -z "$leftover" ] || die "$file 里还有未替换的占位符: $leftover"
}

# 临时目录：0700，退出时删。用来接 xray 生成的密钥，避免值经过命令行参数。
make_tmpdir() {
    local dir
    dir="$(mktemp -d)"
    chmod 700 "$dir"
    printf '%s' "$dir"
}

# ==================== xray 运行时 ====================
xray_present() { [ -x "$XRAY_BIN" ]; }

xray_version() {
    xray_present || return 1
    "$XRAY_BIN" version 2>/dev/null | head -1
}

# 相当于 nginx -t：先测再重启。
# 绝不用 -dump —— 那会把合并后的配置（含私钥和口令）打印到终端和日志里。
xray_test_config() {
    local output
    if output="$("$XRAY_BIN" run -test -confdir "$XRAY_CONF_DIR" 2>&1)"; then
        log_success "配置测试通过（xray run -test）"
        return 0
    fi
    log_error "配置测试未通过，没有重启服务。原始输出："
    printf '%s\n' "$output" >&2
    return 1
}

# 某个端口是不是本机 xray 在听（用于判断「端口忙」是不是自己占的）
port_listened_by_xray() {
    local port="$1"
    ss -tlnpH 2>/dev/null \
        | awk -v p=":$port" '{ for (i = 1; i <= NF; i++) if ($i ~ (p "$")) { print; exit } }' \
        | grep -q 'xray'
}

port_listening() {
    local port="$1"
    ss -tlnH 2>/dev/null \
        | awk -v p=":$port" '{ for (i = 1; i <= NF; i++) if ($i ~ (p "$")) { f = 1; exit } } END { exit(f ? 0 : 1) }'
}

# 端口归属检查：free 可用；被自己的 xray 占着算幂等重跑；被别人占着一律停。
require_port_for_xray() {
    local port="$1" label="$2"
    case "$(guard port-free "$port")" in
        free) log_info "端口 $port 空闲（$label）" ;;
        unknown)
            # ss 和 netstat 都不在，查不了。「查不了」不等于「空闲」，
            # 不能默默往一个可能有人在听的端口上写配置。
            die "这台机器上既没有 ss 也没有 netstat，无法确认端口 $port 是否空闲。先装上：apt-get install -y iproute2"
            ;;
        busy)
            if port_listened_by_xray "$port"; then
                log_info "端口 $port 已由本机 xray 监听（$label），按重跑处理"
            else
                log_error "端口 $port 被别的程序占用，不动它。占用情况："
                ss -tlnp 2>/dev/null | awk -v p=":$port" '{ for (i = 1; i <= NF; i++) if ($i ~ (p "$")) { print; exit } }' >&2
                die "换一个端口，或先停掉占用者。"
            fi
            ;;
    esac
}

# 测试 -> 重启 -> 拿真证据（服务活着、端口真的在听）。任何一步失败都如实报错。
xray_apply() {
    local expect_port="${1:-}"
    xray_test_config || return 1
    systemctl daemon-reload
    systemctl enable xray >/dev/null 2>&1 || true
    systemctl restart xray
    sleep 2
    if ! systemctl is-active --quiet xray; then
        log_error "xray 启动失败，最近日志："
        journalctl -u xray -n 20 --no-pager >&2 || true
        return 1
    fi
    log_success "xray 运行中（systemctl is-active: active）"
    if [ -n "$expect_port" ]; then
        if port_listening "$expect_port"; then
            log_success "端口 $expect_port 正在监听"
        else
            log_error "服务活着，但端口 $expect_port 没在监听 —— 配置生效了吗？"
            journalctl -u xray -n 20 --no-pager >&2 || true
            return 1
        fi
    fi
}

# 当前装了哪些入站片段（10-/20- 开头的文件），basename 列表
inbound_fragments() {
    [ -d "$XRAY_CONF_DIR" ] || return 0
    find "$XRAY_CONF_DIR" -maxdepth 1 -type f -name '[1-9]*.json' -printf '%f\n' 2>/dev/null | sort
}

# 防火墙只做提示，不代改：改防火墙的风险（把自己关在门外）比它省下的事大，
# 而云服务商的安全组根本不在这台机器上，脚本无论如何也管不到。
notice_firewall() {
    local port="$1" n=1
    echo "" >&2
    log_warning "还需要你自己做的事：放行 ${port}/TCP"
    echo "  $((n++)). 云服务商控制台的安全组 / 防火墙规则里放行 ${port}/TCP（最容易漏的一步）" >&2
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
        echo "  $((n++)). 这台机器上 ufw 是开着的，还要执行： sudo ufw allow ${port}/tcp" >&2
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        echo "  $((n++)). 这台机器上 firewalld 是开着的，还要执行： sudo firewall-cmd --add-port=${port}/tcp --permanent && sudo firewall-cmd --reload" >&2
    fi
}
