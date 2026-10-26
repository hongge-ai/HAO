#!/usr/bin/env bash
set -euo pipefail

# science/ 模块的离线测试：不装任何东西、不碰主机，只验证
#   1. 每个模板渲染后是合法 JSON（含 // 注释的剥离）
#   2. 落到主机上的文件都带 `Managed by HAO` 头（hao-guard.sh 靠它判归属）
#   3. 两个容易致命的细节没有回归：
#      - http 入站的账号字段必须是 accounts（写成 users 会变成无认证的开放代理）
#      - vless:// 分享链接必须成形（模板里 UUID 占位符后紧跟一个字面 @）
#   4. 入口脚本的参数校验会拒绝该拒绝的东西（尤其是命令行传口令）
#
# 这些是 references/ 里的散文测不到、但一旦错了后果很具体的部分。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCIENCE_DIR="$ROOT_DIR/science"
SECRET_SH="$ROOT_DIR/skills/hao-deploy/scripts/hao-secret.sh"

command -v python3 >/dev/null 2>&1 || { echo "需要 python3 来校验 JSON" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "  ✗ $*" >&2; exit 1; }
ok()   { echo "  ✓ $*"; }

# 把 // 行注释剥掉再交给 json.tool —— xray 自己也是这么做的
# （infra/conf/serial/loader.go 用一个会剥注释的 reader）。
assert_json() {
    local file="$1" label="$2"
    python3 - "$file" <<'PY' || fail "$label 不是合法 JSON（剥掉 // 注释之后）"
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
stripped = re.sub(r'^\s*//.*$', '', raw, flags=re.M)
json.loads(stripped)
PY
    ok "$label 是合法 JSON"
}

assert_contains() {
    local file="$1" needle="$2" label="$3"
    grep -qF -- "$needle" "$file" || fail "$label：期望包含 $needle"
    ok "$label 包含 $needle"
}

# `|| true`：pipefail 下 grep 找不到东西会让整条赋值失败，
# 而「找不到占位符」正是我们期望的结果。
assert_no_placeholder() {
    local file="$1" label="$2" leftover
    leftover="$(grep -oE '@@[A-Z][A-Z0-9_]*@@' "$file" | sort -u | tr '\n' ' ' || true)"
    [ -z "$leftover" ] || fail "$label 还有未替换的占位符: $leftover"
    ok "$label 没有残留占位符"
}

# ==================== 1. 逐字安装的模板 ====================
echo "== 逐字安装的模板带归属头 =="
for f in xray.service 00-base.json sysctl-bbr.conf certbot-deploy-hook-xray.sh.tmpl; do
    path="$SCIENCE_DIR/templates/$f"
    [ -f "$path" ] || fail "模板缺失: $f"
    head -n 12 "$path" | grep -q 'Managed by HAO' || fail "$f 缺少 Managed by HAO 头"
    head -n 12 "$path" | grep -qE '^(#|//) Service: ' || fail "$f 缺少 Service: 头"
    assert_no_placeholder "$path" "$f"
done
ok "四个逐字模板的注释头都在"

# 每个占位符都必须在该模板的注释里被说明（和 skill 侧同一条规则：
# 只看注释行，否则短模板里"自己被用到"就算通过，检查等于没有）
undocumented=0
for tmpl in "$SCIENCE_DIR"/templates/*; do
    case "$(basename "$tmpl")" in
        # 这两个渲染出来是给**用户**看的纯文本（/etc/hao/*.client.txt），
        # 加注释块会把"占位符说明"渲进用户看到的内容里。它们的取值在
        # lib/*.sh 的 render_plain 调用处逐个列着，那里才是说明的位置。
        *-client.txt.tmpl) continue ;;
    esac
    comments="$(grep -E '^[[:space:]]*(#|//)' "$tmpl" || true)"
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case "$comments" in
            *"$tok"*) ;;
            *) echo "  ✗ $(basename "$tmpl") 用了 $tok 但注释里没说明它" >&2; undocumented=1 ;;
        esac
    done < <(grep -ohE '@@[A-Z][A-Z0-9_]*@@' "$tmpl" | sort -u)
done
[ "$undocumented" -eq 0 ] || exit 1
ok "每个模板的占位符都在注释里有说明（客户端信息模板除外，见注释）"

assert_json "$SCIENCE_DIR/templates/00-base.json" "00-base.json"
# 私有地址必须被挡掉：带认证的公网代理如果能穿进 127.0.0.1，
# 等于把本机所有「只监听回环所以没设密码」的服务暴露给拿到口令的人。
assert_contains "$SCIENCE_DIR/templates/00-base.json" 'geoip:private' "00-base.json"
assert_contains "$SCIENCE_DIR/templates/00-base.json" '"access": "none"' "00-base.json"
# 单元必须用 -confdir，否则「一个工具一个配置文件」整套设计就不成立
assert_contains "$SCIENCE_DIR/templates/xray.service" '-confdir' "xray.service"

# ==================== 2. 造一份假凭据 ====================
echo ""
echo "== 渲染（两段式：非密钥 sed + hao-secret.sh render）=="
CRED="$WORK/fake.env"
FAKE_PRIVATE="cHJpdmF0ZS1rZXktZm9yLXRlc3Rpbmc" \
FAKE_PUBLIC="cHVibGljLWtleS1mb3ItdGVzdGluZw" \
FAKE_UUID="11111111-2222-3333-4444-555555555555" \
FAKE_SHORTID="0123456789abcdef" \
FAKE_USER="example-usr" \
FAKE_PASS="not-a-real-password" \
"$SECRET_SH" write "$CRED" \
    PRIVATE_KEY=@env:FAKE_PRIVATE \
    PUBLIC_KEY=@env:FAKE_PUBLIC \
    UUID=@env:FAKE_UUID \
    SHORT_ID=@env:FAKE_SHORTID \
    PROXY_USER=@env:FAKE_USER \
    PROXY_PASSWORD=@env:FAKE_PASS >/dev/null
ok "假凭据已生成（$CRED）"

# 模拟 lib 里的第一段：把非密钥占位符替换掉
render_plain() {
    local template="$1" output="$2"
    shift 2
    local content pair key value
    content="$(cat "$template")"
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        content="${content//@@${key}@@/$value}"
    done
    printf '%s\n' "$content" > "$output"
}

# ---- Reality 入站 ----
render_plain "$SCIENCE_DIR/templates/10-reality.json.tmpl" "$WORK/10.staged" \
    PORT=8443 DEST_SNI=www.microsoft.com
"$SECRET_SH" render "$WORK/10.staged" "$WORK/10-reality.json" --from "$CRED" --mode 0600 >/dev/null
assert_no_placeholder "$WORK/10-reality.json" "10-reality.json"
assert_json "$WORK/10-reality.json" "10-reality.json"
assert_contains "$WORK/10-reality.json" '"security": "reality"' "10-reality.json"
assert_contains "$WORK/10-reality.json" '"port": 8443' "10-reality.json"
head -n 12 "$WORK/10-reality.json" | grep -q 'Managed by HAO' || fail "10-reality.json 丢了归属头"
ok "10-reality.json 保留了归属头"

# ---- HTTPS 代理入站 ----
render_plain "$SCIENCE_DIR/templates/20-httpsproxy.json.tmpl" "$WORK/20.staged" \
    PORT=8444 DOMAIN=proxy.example.com \
    CERT_FULLCHAIN=/etc/letsencrypt/live/proxy.example.com/fullchain.pem \
    CERT_KEY=/etc/letsencrypt/live/proxy.example.com/privkey.pem
"$SECRET_SH" render "$WORK/20.staged" "$WORK/20-httpsproxy.json" --from "$CRED" --mode 0600 >/dev/null
assert_no_placeholder "$WORK/20-httpsproxy.json" "20-httpsproxy.json"
assert_json "$WORK/20-httpsproxy.json" "20-httpsproxy.json"
head -n 12 "$WORK/20-httpsproxy.json" | grep -q 'Managed by HAO' || fail "20-httpsproxy.json 丢了归属头"
ok "20-httpsproxy.json 保留了归属头"

# 这一条是整个文件里最要紧的断言：
# 字段名写成 users（上游文档的错误写法）不会报错，会静默变成**无认证的开放代理**。
python3 - "$WORK/20-httpsproxy.json" <<'PY' || fail "http 入站的账号字段不对"
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
cfg = json.loads(re.sub(r'^\s*//.*$', '', raw, flags=re.M))
inbound = cfg["inbounds"][0]
assert inbound["protocol"] == "http", inbound["protocol"]
settings = inbound["settings"]
assert "accounts" in settings, "缺少 accounts —— 会变成无认证的开放代理"
assert "users" not in settings, "写成了 users，xray 不认这个字段"
assert settings["accounts"][0]["user"] == "example-usr"
assert settings["accounts"][0]["pass"] == "not-a-real-password"
assert settings["allowTransparent"] is False
stream = inbound["streamSettings"]
assert stream["security"] == "tls", stream["security"]
tls = stream["tlsSettings"]
assert tls["alpn"] == ["http/1.1"], tls["alpn"]
assert tls["serverName"] == "proxy.example.com"
assert tls["certificates"][0]["certificateFile"].endswith("fullchain.pem")
assert tls["certificates"][0]["keyFile"].endswith("privkey.pem")
assert inbound["port"] == 8444
PY
ok "http 入站是 accounts + TLS + Basic 认证（不是无认证的开放代理）"

# ==================== 3. 客户端信息 ====================
echo ""
echo "== 客户端信息文件 =="
render_plain "$SCIENCE_DIR/templates/reality-client.txt.tmpl" "$WORK/rc.staged" \
    SERVER_IP=203.0.113.10 PORT=8443 DEST_SNI=www.microsoft.com \
    NODE_NAME=reality-8443 GENERATED_AT=2026-01-01T00:00:00Z
"$SECRET_SH" render "$WORK/rc.staged" "$WORK/reality-client.txt" --from "$CRED" --mode 0600 >/dev/null
assert_no_placeholder "$WORK/reality-client.txt" "reality-client.txt"
# 链接必须成形：模板里 UUID 占位符后面紧跟一个字面 @，写错就会得到 vless://<uuid><ip>
grep -qE '^vless://11111111-2222-3333-4444-555555555555@203\.0\.113\.10:8443\?' "$WORK/reality-client.txt" \
    || fail "vless:// 分享链接没有成形"
ok "vless:// 分享链接成形"

render_plain "$SCIENCE_DIR/templates/httpsproxy-client.txt.tmpl" "$WORK/pc.staged" \
    DOMAIN=proxy.example.com PORT=8444 NODE_NAME=proxy-8444 \
    CERT_KIND="Let's Encrypt" GENERATED_AT=2026-01-01T00:00:00Z
"$SECRET_SH" render "$WORK/pc.staged" "$WORK/httpsproxy-client.txt" --from "$CRED" --mode 0600 >/dev/null
assert_no_placeholder "$WORK/httpsproxy-client.txt" "httpsproxy-client.txt"
# 用户要的就是这一行：https 域名 端口 用户名 口令
grep -qE '^https proxy\.example\.com 8444 example-usr not-a-real-password$' "$WORK/httpsproxy-client.txt" \
    || fail "缺少「https 域名 端口 用户名 口令」那一行"
ok "客户端一行形式正确"
assert_contains "$WORK/httpsproxy-client.txt" "只转 TCP" "httpsproxy-client.txt"

render_plain "$SCIENCE_DIR/templates/curl-proxy-check.conf.tmpl" "$WORK/cc.staged" \
    DOMAIN=proxy.example.com PORT=8444
"$SECRET_SH" render "$WORK/cc.staged" "$WORK/curl.conf" --from "$CRED" --mode 0600 >/dev/null
assert_no_placeholder "$WORK/curl.conf" "curl-proxy-check.conf"
assert_contains "$WORK/curl.conf" 'proxy-user = "example-usr:not-a-real-password"' "curl-proxy-check.conf"

# ==================== 4. 入口脚本的拒绝条件 ====================
echo ""
echo "== install.sh 参数校验 =="
INSTALL="$SCIENCE_DIR/install.sh"
[ -x "$INSTALL" ] || fail "install.sh 不可执行"

"$INSTALL" -h >/dev/null 2>&1 || fail "install.sh -h 应该退出 0"
ok "install.sh -h 正常"

out="$("$INSTALL" -h 2>&1)"
case "$out" in
    *"Reality 入站（默认 443）"*"HTTPS 正向代理（默认 8443）"*) ok "入口帮助使用新的默认端口" ;;
    *) fail "入口帮助应显示 Reality 443、HTTPS 代理 8443，实际输出: $out" ;;
esac

out="$("$INSTALL" reality -h 2>&1)"
case "$out" in
    *"监听端口（默认 443）"*"伪装目标站点（默认 www.bing.com）"*) ok "Reality 帮助使用新的默认端口和 SNI" ;;
    *) fail "Reality 帮助应显示 443 和 www.bing.com，实际输出: $out" ;;
esac

out="$("$INSTALL" proxy -h 2>&1)"
case "$out" in
    *"监听端口（默认 8443）"*) ok "HTTPS 代理帮助使用新的默认端口" ;;
    *) fail "HTTPS 代理帮助应显示 8443，实际输出: $out" ;;
esac

if "$INSTALL" nonsense >/dev/null 2>&1; then
    fail "未知子命令应该退出非 0"
fi
ok "未知子命令被拒绝"

# 命令行传口令必须被拒绝：argv 同机任何用户都能从 /proc/<pid>/cmdline 读到
out="$("$INSTALL" proxy --domain d.example.com --password hunter2 2>&1 || true)"
case "$out" in
    *"不接受用命令行参数传口令"*) ok "命令行传口令被拒绝" ;;
    *) fail "--password 应该被明确拒绝，实际输出: $out" ;;
esac

out="$("$INSTALL" proxy 2>&1 || true)"
case "$out" in
    *"必须给 --domain"*) ok "缺少 --domain 被拒绝" ;;
    *) fail "proxy 缺少 --domain 时应该报错，实际输出: $out" ;;
esac

out="$("$INSTALL" reality --port 99999 2>&1 || true)"
case "$out" in
    *"端口必须是 1-65535"*) ok "非法端口被拒绝" ;;
    *) fail "非法端口应该被拒绝，实际输出: $out" ;;
esac

echo ""
echo "science 模块测试通过"
