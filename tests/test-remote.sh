#!/usr/bin/env bash
set -euo pipefail

# hao-remote.sh 的行为测试。
#
# 全部离线：用一个假 ssh 桩替掉真连接，桩把每次调用的 argv 记下来，并回放
# 预置的输出。真实服务器上的端到端验证不在这里做（CI 没有服务器），
# 需要时设 HAO_TEST_REMOTE_TARGET 手动跑最后一节。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="$ROOT_DIR/skills/hao-deploy/scripts/hao-remote.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

# 假 ssh：把每次调用的参数写到 $WORK/argv.log，再按 $WORK/reply 里的内容回放。
# 不同的子命令需要不同的回复，所以用「第一个参数里出现的特征串」来挑回复。
make_stub() {
    cat > "$WORK/fake-ssh" <<'STUB'
#!/usr/bin/env bash
# 记录 argv，每行一条，字段用 \x1f 分隔（参数里可能有空格）。
log="${FAKE_SSH_LOG:?}"
printf '%s' "$1" >/dev/null
{ printf '%s\x1f' "$@"; printf '\n'; } >> "$log"

# -G：按 config 文件是否有内容来区分「基线」与「真实 config」。
# 基线用的是空的 mktemp 文件，名字随机，只能看内容。
for a in "$@"; do
    if [ "$a" = "-G" ]; then
        cfg=""
        prev=""
        for x in "$@"; do
            [ "$prev" = "-F" ] && cfg="$x"
            prev="$x"
        done
        # 取最后一个非选项参数当作目标，拆出 user@host。
        target=""
        skip=0
        for x in "$@"; do
            if [ "$skip" = 1 ]; then skip=0; continue; fi
            case "$x" in
                -F|-o|-p|-l) skip=1 ;;
                -*) ;;
                -G) ;;
                *) target="$x" ;;
            esac
        done
        tuser="$FAKE_USER"
        thost="$target"
        tport="$FAKE_PORT"
        case "$target" in
            *@*) tuser="${target%@*}"; thost="${target#*@}" ;;
        esac
        # -p 覆盖端口；配置里的 Host 也带 Port 时以 -p 为准（和真 ssh 一致）。
        prev=""
        for x in "$@"; do
            [ "$prev" = "-p" ] && tport="$x"
            prev="$x"
        done
        if [ -s "$cfg" ]; then
            echo "hostname $FAKE_HOST"; echo "user $tuser"; echo "port $tport"
        else
            echo "hostname $thost"; echo "user $tuser"; echo "port $tport"
        fi
        exit 0
    fi
done

# 其余调用按 $FAKE_REPLY 回放。
[ -f "${FAKE_REPLY:-/nonexistent}" ] && cat "$FAKE_REPLY"
exit "${FAKE_RC:-0}"
STUB
    chmod +x "$WORK/fake-ssh"
}

make_stub

run() {
    # run <expected-rc> <args...>
    local want="$1"; shift
    local rc=0
    "$@" || rc=$?
    [ "$rc" = "$want" ] || fail "期望 rc=$want，实际 rc=$rc：$*"
}

out() {
    # out <args...> —— 返回 stdout
    "$@" 2>/dev/null
}

export HAO_REMOTE_STATE_DIR="$WORK/state"
export HAO_KEY="$WORK/id_test"
export HAO_KNOWN_HOSTS_FILE="$WORK/known_hosts"
# 把 HOME 指到临时目录，让 ssh_config_file() 指向一个可控的文件。
# 桩靠「config 非空」区分真实 config 与空基线文件。
REAL_HOME="$HOME"
export HOME="$WORK/home"
export XDG_STATE_HOME=""
mkdir -p "$HOME/.ssh"
printf 'Host blog\n  HostName 203.0.113.9\n  User deploy\n  Port 2222\n' > "$HOME/.ssh/config"
# Windows 上 ssh_config_file() 走 USERPROFILE，同样指过去，否则测试会读写真实配置。
export USERPROFILE="$HOME"
export FAKE_SSH_LOG="$WORK/argv.log"
export FAKE_TARGET_AS_IS="some-target"
export FAKE_HOST="203.0.113.9"
export FAKE_USER="deploy"
export FAKE_PORT="2222"

# 用假 ssh 跑：脚本探测 ssh 家族时会看 HAO_SSH_BIN 所在目录，
# 所以把桩复制成同名文件，再把 keyscan/keygen 也指过去。
cp "$WORK/fake-ssh" "$WORK/ssh"
cp "$WORK/fake-ssh" "$WORK/ssh-keygen"
cp "$WORK/fake-ssh" "$WORK/ssh-keyscan"
chmod +x "$WORK"/ssh "$WORK"/ssh-keygen "$WORK"/ssh-keyscan
export HAO_SSH_BIN="$WORK/ssh"

# ---------------------------------------------------------------- resolve
printf '== resolve ==\n'

# 别名：空 config 解析出的 hostname 是目标本身，真实 config 是 HostName。
export FAKE_TARGET_AS_IS="blog"
res="$(out env HAO_SSH_BIN="$WORK/ssh" "$REMOTE" resolve blog)"
printf '%s\n' "$res" | grep -qx 'mode=alias' || fail "别名应识别为 alias，实际：$res"
printf '%s\n' "$res" | grep -qx 'host=203.0.113.9' || fail "别名应取 HostName"
printf '%s\n' "$res" | grep -qx 'user=deploy' || fail "别名应取 User"
pass "别名解析"

# 地址：两次解析 hostname 相同。
res="$(out env FAKE_HOST=198.51.100.7 FAKE_TARGET_AS_IS=198.51.100.7 \
    "$REMOTE" resolve root@198.51.100.7)"
printf '%s\n' "$res" | grep -qx 'mode=address' || fail "地址应识别为 address"
printf '%s\n' "$res" | grep -qx 'user=root' || fail "user@host 应取 root"
printf '%s\n' "$res" | grep -qx 'user_from=argument' || fail "用户应来自参数"
pass "地址解析"

# Windows 默认用户名必须拒绝：DOMAIN\user 在 Linux 上不存在。
rc=0
out env FAKE_USER='CORP\alice' FAKE_TARGET_AS_IS=198.51.100.7 \
    "$REMOTE" resolve 198.51.100.7 >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "DOMAIN\\\\user 应被拒绝"
pass "拒绝 Windows 默认用户"

# 端口覆盖必须生效。
res="$(out env "$REMOTE" resolve --port 46868 root@198.51.100.7)"
printf '%s\n' "$res" | grep -qx 'port=46868' || fail "--port 未生效：$res"
pass "--port 覆盖"

# ---------------------------------------------------------------- shq / 引用
printf '== 参数引用 ==\n'
# 通过 source 取到 shq 单独测，避免依赖远端。
# shellcheck source=/dev/null
. <(sed -n '/^shq() {/,/^}/p' "$REMOTE")
[ "$(shq "it's")" = "'it'\\''s'" ] || fail "shq 单引号转义错误：$(shq "it's")"
[ "$(shq 'a&b')" = "'a&b'" ] || fail "shq 不应解释 &"
[ "$(shq '')" = "''" ] || fail "shq 空串应输出 ''"
# 反引号与 $ 必须原样保留（在单引号里本来就安全）。
[ "$(shq 'echo $HOME `id`')" = "'echo \$HOME \`id\`'" ] || fail "shq 破坏了 \$ 或反引号"
pass "shq 转义"

# ---------------------------------------------------------------- bundle
printf '== bundle 归一化 ==\n'
# 造一个 CRLF 的 skill 目录，验证打包后没有 \r。
SRC="$WORK/skills/hao-deploy"
mkdir -p "$SRC/scripts" "$SRC/templates"
printf '#!/usr/bin/env bash\r\nset -euo pipefail\r\necho hi\r\n' > "$SRC/scripts/hao-guard.sh"
printf 'set -euo pipefail\n' > "$SRC/scripts/hao-secret.sh"
printf 'set -euo pipefail\n' > "$SRC/scripts/hao-state.sh"
printf 'server { }\r\n' > "$SRC/templates/nginx.conf"
printf 'a\n' > "$SRC/templates/x.conf"

# 用脚本里的函数，但把 SKILL_SRC 指到临时目录。
DUMMY="$WORK/scripts/hao-remote.sh"
mkdir -p "$WORK/scripts"
cp "$REMOTE" "$DUMMY"
out env SKILL_OVERRIDE=1 bash -c '
    set -euo pipefail
    src="$1"
    # 取 build_bundle_into / tree_hash 的函数体，改掉 SKILL_SRC。
    eval "$(sed -n "/^build_bundle_into() {/,/^}/p" "$src")"
    eval "$(sed -n "/^tree_hash() {/,/^}/p" "$src")"
    SKILL_SRC="$2"
    st="$(mktemp -d)"
    build_bundle_into "$st"
    if grep -rqU $'"'"'\r'"'"' "$st"; then echo "CR REMAINED"; exit 1; fi
    n=$(find "$st" -type f | wc -l)
    [ "$n" = 5 ] || { echo "FILE COUNT $n"; exit 1; }
    # 可执行位保留在 scripts/ 下。
    [ -x "$st/scripts/hao-guard.sh" ] || { echo "NOT EXEC"; exit 1; }
    echo "NORMALIZED"
' _ "$REMOTE" "$SRC" | grep -qx NORMALIZED || fail "bundle 未归一化 CRLF"
pass "CRLF 归一化"

# 同一个目录算两次哈希必须相同（顺序稳定）。
h1="$(out bash -c '
    eval "$(sed -n "/^build_bundle_into() {/,/^}/p" "$1")"
    eval "$(sed -n "/^tree_hash() {/,/^}/p" "$1")"
    SKILL_SRC="$2"
    st="$(mktemp -d)"; build_bundle_into "$st"; tree_hash "$st"; rm -rf "$st"
' _ "$REMOTE" "$SRC")"
h2="$(out bash -c '
    eval "$(sed -n "/^build_bundle_into() {/,/^}/p" "$1")"
    eval "$(sed -n "/^tree_hash() {/,/^}/p" "$1")"
    SKILL_SRC="$2"
    st="$(mktemp -d)"; build_bundle_into "$st"; tree_hash "$st"; rm -rf "$st"
' _ "$REMOTE" "$SRC")"
[ "$h1" = "$h2" ] || fail "tree_hash 不稳定：$h1 != $h2"
[ "${#h1}" = 64 ] || fail "tree_hash 应是 64 位，实际 ${#h1}"
pass "tree_hash 稳定"

# ---------------------------------------------------------------- 拒绝路径
printf '== 拒绝路径 ==\n'

# 没有 --fingerprint 的 bootstrap 必须拒绝。
rc=0
out "$REMOTE" bootstrap blog >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "bootstrap 缺少 --fingerprint 时应拒绝"
pass "bootstrap 强制指纹"

# 指纹不匹配必须拒绝。
: > "$WORK/scan.txt"
rc=0
out env FAKE_REPLY="$WORK/scan.txt" "$REMOTE" bootstrap blog \
    --fingerprint 'SHA256:deadbeef' >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "指纹不匹配时应拒绝"
pass "指纹不匹配拒绝"

# cleanup 在没有会话时是 no-op。
rc=0
out "$REMOTE" cleanup blog >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || fail "无会话的 cleanup 应安静返回"
pass "cleanup 无会话"

# ---------------------------------------------------------------- 状态文件
printf '== 状态文件 ==\n'
# targets 在没有登记时给出提示而不是报错。
out "$REMOTE" targets | grep -q '还没有登记' || fail "空 targets 应有提示"
pass "targets 空状态"

# ---------------------------------------------------------------- argv 里没有密码
printf '== 密码不进 argv ==\n'
# 扫描整个脚本，确认没有任何把密码值拼进命令行的路径。
if grep -qE 'sshpass|PASSWORD=.*\$|password=.*\$' "$REMOTE"; then
    fail "脚本里出现了把密码拼进参数的模式"
fi
pass "无密码入参模式"

# ---------------------------------------------------------------- 可选：真机
if [ -n "${HAO_TEST_REMOTE_TARGET:-}" ]; then
    printf '== 真机端到端（%s）==\n' "$HAO_TEST_REMOTE_TARGET"
    # 前面把 HOME/HAO_KEY 等都指到了临时目录，真机段必须回到真实环境。
    unset HAO_REMOTE_STATE_DIR HAO_KEY HAO_KNOWN_HOSTS_FILE HAO_SSH_BIN
    unset XDG_STATE_HOME USERPROFILE
    export HOME="${REAL_HOME:?}"
    T="$HAO_TEST_REMOTE_TARGET"
    "$REMOTE" probe "$T" | grep -q '^os_id=' || fail "probe 失败"
    s="$("$REMOTE" session "$T")"
    # 返回的是**远端**路径，本机不存在的，所以不能 [ -d ]；用远端验证。
    printf '%s\n' "$s" | grep -q '^/tmp/hao\.' || fail "session 未返回远端路径：[$s]"
    "$REMOTE" exec "$T" - <<'EOF' | grep -q 'supported' || fail "远端 hao-guard 失败"
"$SKILL/scripts/hao-guard.sh" os-supported
EOF
    "$REMOTE" cleanup "$T" >/dev/null || fail "cleanup 失败"
    pass "真机链路"
else
    printf '  跳过真机测试（未设置 HAO_TEST_REMOTE_TARGET）\n' >&2
fi

echo "remote 测试通过"
