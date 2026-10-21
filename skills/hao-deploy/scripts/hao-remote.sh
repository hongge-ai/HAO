#!/usr/bin/env bash
# shellcheck shell=bash

# hao-remote.sh —— 从本机通过 SSH 操作目标服务器
#
# 这个脚本存在的唯一理由：让 HAO 的过程文档（references/）在「agent 跑在
# 笔记本上、目标是远程服务器」的模式下照常执行，而不需要改写那 98 处
# "$SKILL/scripts/..." 调用。
#
# 它只做传输与认证，不含任何模块知识。装什么由 agent 在一轮对话里问用户决定。
#
# 三条安全底线：
#   1. 密码不进 argv、不进对话、不进日志。首次装公钥由用户跑 ssh-copy-id，
#      或由 askpass 读一个用户自建的 0600 文件；本脚本只经手路径。
#   2. 主机密钥钉死。首次连接必须显式给出 --fingerprint；此后的任何变更都是
#      硬失败，不是「更新一下」。
#   3. 远端脚本先过 bash -n、无 CR、树哈希一致三道门禁，才允许执行。
#
# 用法:
#   hao-remote.sh resolve <target>
#   hao-remote.sh hostkey <target>
#   hao-remote.sh bootstrap <target> --fingerprint SHA256:... [--copy-id|--askpass] [--alias NAME]
#   hao-remote.sh probe <target>
#   hao-remote.sh session <target>
#   hao-remote.sh push <target>
#   hao-remote.sh exec <target> [--tty] -- <command...>
#   hao-remote.sh exec <target> -            (脚本从 stdin 读)
#   hao-remote.sh cleanup <target> [--all]
#   hao-remote.sh targets

set -euo pipefail

die() {
    echo "hao-remote: $*" >&2
    exit 1
}

note() {
    echo "hao-remote: $*" >&2
}

# ==================== 平台与路径 ====================
# 注意：这里**不能**设 MSYS2_ARG_CONV_EXCL='*'。
# 它会让 MSYS 跳过所有参数转换，于是 `-o IdentityFile=/c/Users/...` 被原样
# 交给原生 ssh.exe —— 而 ssh.exe 不认识 /c/Users 这种路径，找不到私钥，
# 认证直接失败（实测：加上它 rc=255，去掉 rc=0）。
# 反过来靠 win_path 显式转换每一个交给 .exe 的路径，行为更可预测：
# 远端命令里的 /etc/nginx 之类只在 ssh 的 remote-command 字符串里出现，
# 不需要 MSYS 干预。

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="$(cd "$SELF_DIR/.." && pwd)"

STATE_DIR="${HAO_REMOTE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/hao/remote}"
STATE_DIR="${STATE_DIR%/}"
TARGETS_TSV="$STATE_DIR/targets.tsv"
ASKPASS_CMD="$STATE_DIR/askpass.cmd"
HAO_KEY="${HAO_KEY:-$HOME/.ssh/hao_ed25519}"
HAO_KNOWN_HOSTS="${HAO_KNOWN_HOSTS_FILE:-$HOME/.ssh/hao_known_hosts}"

is_windows_shell() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

# 三个工具必须来自同一个目录：known_hosts 的哈希算法和密钥类型支持要一致。
# 路径统一成 Git Bash 形式再判断：$SYSTEMROOT 是 Windows 形式（C:\WINDOWS），
# 直接拼 "/System32/..." 得到的是混合路径，`[ -x ]` 在 MSYS 下判断为假。
pick_ssh_tools() {
    local win_openssh=""
    if is_windows_shell && [ -n "${SYSTEMROOT:-}" ]; then
        win_openssh="$(cygpath -u "$SYSTEMROOT")/System32/OpenSSH"
    fi

    local bindir="" candidate=""
    if [ -n "${HAO_SSH_BIN:-}" ]; then
        SSH_BIN="$HAO_SSH_BIN"
        bindir="$(dirname "$HAO_SSH_BIN")"
    elif [ -n "$win_openssh" ] && [ -x "$win_openssh/ssh.exe" ]; then
        bindir="$win_openssh"
        SSH_BIN="$bindir/ssh.exe"
    elif command -v ssh >/dev/null 2>&1; then
        SSH_BIN="$(command -v ssh)"
        bindir="$(dirname "$SSH_BIN")"
    else
        die "找不到 ssh。Windows 请确认已启用 OpenSSH 客户端；其他系统请安装 openssh-client。"
    fi

    local n var
    for n in ssh-keygen ssh-copy-id; do
        var="$(printf '%s' "$n" | tr 'a-z-' 'A-Z_')"
        candidate=""
        if [ -x "$bindir/$n.exe" ]; then
            candidate="$bindir/$n.exe"
        elif [ -x "$bindir/$n" ]; then
            candidate="$bindir/$n"
        elif command -v "$n" >/dev/null 2>&1; then
            candidate="$(command -v "$n")"
        fi
        printf -v "$var" '%s' "$candidate"
    done

    # ssh-keyscan 单独挑：Windows 原生 9.5 的那个协商不了 sntrup761x25519
    # （OpenSSH 10.x 服务端的默认 KEX），而 Git Bash 自带的 10.x 可以。
    # 扫描结果是一份标准的 known_hosts 行，任何版本的 ssh 都认，所以可以
    # 「用新版扫、用原生连」。优先选能工作的扫描器，而不是和 ssh 同目录的那个。
    SSH_KEYSCAN=""
    if [ -n "${HAO_KEYSCAN_BIN:-}" ]; then
        SSH_KEYSCAN="$HAO_KEYSCAN_BIN"
    elif command -v ssh-keyscan >/dev/null 2>&1; then
        SSH_KEYSCAN="$(command -v ssh-keyscan)"
    elif [ -x "$bindir/ssh-keyscan.exe" ]; then
        SSH_KEYSCAN="$bindir/ssh-keyscan.exe"
    elif [ -x "$bindir/ssh-keyscan" ]; then
        SSH_KEYSCAN="$bindir/ssh-keyscan"
    fi
}

pick_ssh_tools

# 传给 .exe 的路径必须是 Windows 形式。
win_path() {
    if is_windows_shell && command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

# native ssh 读 %USERPROFILE%\.ssh\config，Git Bash 的 ssh 读 $HOME/.ssh/config。
# 本机上两者是同一个目录，但不能假设。始终显式 -F，解析结果才和实际连接一致。
ssh_config_file() {
    if is_windows_shell && [ -n "${USERPROFILE:-}" ]; then
        printf '%s/.ssh/config' "$(cd "$USERPROFILE" && pwd)"
    else
        printf '%s/.ssh/config' "$HOME"
    fi
}

# 远端 shell 的单引号转义：' -> '\''
# 不用 ${var//pat/rep}：bash 的替换把 & 当作匹配文本，路径里带 & 会被静默写坏
# （CLAUDE.md 有这条硬约束）。这里用显式循环，也避免 sed 对反斜杠的二次解释。
shq() {
    local s="$1" out="" ch i
    if [ -z "$s" ]; then printf "''"; return 0; fi
    for (( i = 0; i < ${#s}; i++ )); do
        ch="${s:i:1}"
        if [ "$ch" = "'" ]; then
            out+="'\\''"
        else
            out+="$ch"
        fi
    done
    printf "'%s'" "$out"
}

target_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._@:-' '_'
}

target_dir() {
    printf '%s/%s' "$STATE_DIR" "$(target_key "$1")"
}

# ==================== ssh 调用原语 ====================
# 每个调用都显式覆盖一遍安全相关的选项：命令行 -o 优先于 config，所以用户
# config 里的 StrictHostKeyChecking no 之类不会渗入。
# 这些选项是固定的，只随端口变化，直接填进全局数组 —— 用进程替换构造数组
# 在 MSYS 的 bash 下会和 set -e/set -u 打架，代价不值得。
SSH_OPTS=()
build_ssh_opts() {
    local port="$1"
    SSH_OPTS=(
        -o BatchMode=yes
        -o IdentitiesOnly=yes
        -o "IdentityFile=$(win_path "$HAO_KEY")"
        -o PasswordAuthentication=no
        -o KbdInteractiveAuthentication=no
        -o StrictHostKeyChecking=yes
        -o "UserKnownHostsFile=$(win_path "$HAO_KNOWN_HOSTS")"
        -o RequestTTY=no
        -o ConnectTimeout=15
        -o ServerAliveInterval=15
        -o ServerAliveCountMax=4
        -o LogLevel=ERROR
        -p "$port"
    )
}

# ssh_run <host> <port> <remote-command> [stdin-file] [extra-ssh-option...]
# 退出码原样返回：drift 的 1 仍是 1，255 是传输失败，不重映射。
ssh_run() {
    local host="$1" port="$2" cmd="$3" stdin_file="${4:-}"
    if [ $# -ge 4 ]; then shift 4; else shift $#; fi
    build_ssh_opts "$port"
    if [ $# -gt 0 ]; then SSH_OPTS+=("$@"); fi

    # Windows 原生 ssh 9.5 在连接收尾时会往 stderr 打一行
    # "close - IO is still pending on closed socket..."。它是无害的收尾噪声，
    # 但会和真正的错误混在一起被 agent 误读，所以单独过滤。
    local errfile rc=0
    errfile="$(mktemp)"
    if [ -n "$stdin_file" ]; then
        "$SSH_BIN" "${SSH_OPTS[@]}" "$host" "$cmd" < "$stdin_file" 2>"$errfile" || rc=$?
    else
        "$SSH_BIN" "${SSH_OPTS[@]}" "$host" "$cmd" 2>"$errfile" || rc=$?
    fi
    if [ -s "$errfile" ]; then
        grep -v '^close - IO is still pending' "$errfile" >&2 || true
    fi
    rm -f "$errfile"
    return $rc
}

# ==================== resolve ====================
# 判断 <target> 是 ssh config 里的别名还是地址，并取出 host/user/port。
#
# 判据：用空 config 与真实 config 各解析一次，hostname 不同即为别名。
# ssh -G 对不存在的别名不报错，只会把名字回显成 hostname，所以不能用退出码判断。
cmd_resolve() {
    local target="${1:-}"
    [ -n "$target" ] || die "resolve 需要 <target>"

    local cfg empty_cfg real_out base_out
    cfg="$(ssh_config_file)"
    empty_cfg="$(mktemp)"
    local rc=0
    local -a portflag=()
    [ -n "${PORT_OVERRIDE:-}" ] && portflag=(-p "$PORT_OVERRIDE")
    real_out="$("$SSH_BIN" -F "$(win_path "$cfg")" ${portflag[@]+"${portflag[@]}"} -G -- "$target" 2>/dev/null)" || rc=1
    if [ $rc -ne 0 ]; then rm -f "$empty_cfg"; die "ssh -G 解析失败: $target"; fi
    base_out="$("$SSH_BIN" -F "$(win_path "$empty_cfg")" ${portflag[@]+"${portflag[@]}"} -G -- "$target" 2>/dev/null)" || rc=1
    rm -f "$empty_cfg"
    [ $rc -eq 0 ] || die "ssh -G 基线解析失败: $target"

    local host user port base_host
    host="$(printf '%s\n' "$real_out" | sed -n 's/^hostname //p' | head -1)"
    user="$(printf '%s\n' "$real_out" | sed -n 's/^user //p' | head -1)"
    port="$(printf '%s\n' "$real_out" | sed -n 's/^port //p' | head -1)"
    base_host="$(printf '%s\n' "$base_out" | sed -n 's/^hostname //p' | head -1)"

    local mode user_from
    if [ "$host" != "$base_host" ]; then
        mode="alias"; user_from="config"
    else
        mode="address"
        case "$target" in *@*) user_from="argument" ;; *) user_from="default" ;; esac
    fi

    # 能顶掉远端命令、或把 known_hosts 记到别处的指令必须先拒绝，
    # 否则本脚本发出的命令可能根本到不了远端。
    local opt
    for opt in remotecommand hostkeyalias; do
        if printf '%s\n' "$real_out" | grep -Eq "^$opt .+"; then
            die "目标 '$target' 的 ssh config 设置了 $opt，无法安全地远程执行命令。请在 ~/.ssh/config 里移除它。"
        fi
    done

    # Windows 默认用户是 DOMAIN\user，Linux 上没有这个用户，连上去必然失败。
    case "$user" in
        *\\*|'')
            die "目标 '$target' 解析出的用户是 '$user'（Windows 默认用户名）。请写成 user@host，或在 ssh config 里设置 User。"
            ;;
    esac

    printf 'mode=%s\nhost=%s\nuser=%s\nport=%s\nuser_from=%s\nconfig_file=%s\n' \
        "$mode" "$host" "$user" "$port" "$user_from" "$cfg"
}

resolved() {
    cmd_resolve "$1" | sed -n "s/^$2=//p" | head -1
}

# ==================== hostkey ====================
# 取主机密钥与指纹，只读，不写任何文件。
#
# 优先 ssh-keyscan。Windows 原生 OpenSSH 9.5 的 ssh-keyscan 有个已知问题：
# 它协商不了 sntrup761x25519（OpenSSH 10.x 服务端的默认 KEX），会直接报
# "unsupported KEX method"。同一个 9.5 的 ssh.exe 却能正常连上，所以退路是
# 用 ssh -v 取 "Server host key:" 行。
scan_hostkeys() {
    local host="$1" port="$2" scan="" line
    if [ -n "$SSH_KEYSCAN" ]; then
        scan="$("$SSH_KEYSCAN" -T 10 -p "$port" -t ed25519,ecdsa,rsa "$host" 2>/dev/null || true)"
        if printf '%s\n' "$scan" | grep -qv '^#' && [ -n "$scan" ]; then
            printf '%s\n' "$scan"
            return 0
        fi
        note "ssh-keyscan 不可用（客户端版本可能过旧），改用 ssh 取主机密钥。" >&2
    fi

    # 原生 ssh.exe 不认 /dev/null，用一个空的临时 known_hosts 代替。
    local scratch
    scratch="$(mktemp)"
    local probe
    probe="$("$SSH_BIN" -v -o BatchMode=yes -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$(win_path "$scratch")" -o ConnectTimeout=10 \
        -o PreferredAuthentications=none -p "$port" "$host" true 2>&1 || true)"
    rm -f "$scratch"
    local out=""
    while IFS= read -r line; do
        case "$line" in
            *"Server host key: "*)
                # debug1: Server host key: ssh-ed25519 SHA256:AbCd...
                out+="${line#*Server host key: }"$'\n'
                ;;
        esac
    done <<< "$probe"
    [ -n "$out" ] || return 1
    printf 'FINGERPRINT-ONLY %s' "$out"
}

cmd_hostkey() {
    local target="${1:-}"
    [ -n "$target" ] || die "hostkey 需要 <target>"
    [ -n "$SSH_KEYGEN" ] || die "找不到 ssh-keygen。"

    local host port
    host="$(resolved "$target" host)"
    port="$(resolved "$target" port)"

    local scan
    scan="$(scan_hostkeys "$host" "$port")" \
        || die "取不到 $host:$port 的主机密钥。确认地址和端口可达，且不是被中间设备拦截。"

    local trusted="none" lookup="$host" user_kh="$HOME/.ssh/known_hosts"
    [ "$port" = "22" ] || lookup="[$host]:$port"
    if [ -f "$user_kh" ] && "$SSH_KEYGEN" -F "$lookup" -f "$user_kh" >/dev/null 2>&1; then
        trusted="user-known-hosts"
    fi

    printf 'host=%s\nport=%s\ntrusted=%s\n' "$host" "$port" "$trusted"

    case "$scan" in
        FINGERPRINT-ONLY*)
            local rest="${scan#FINGERPRINT-ONLY }" line
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                printf 'fingerprint=%s type=%s\n' \
                    "$(printf '%s' "$line" | awk '{print $2}')" \
                    "$(printf '%s' "$line" | awk '{print $1}')"
            done <<< "$rest"
            ;;
        *)
            local line type fp
            while IFS= read -r line; do
                case "$line" in ''|'#'*) continue ;; esac
                type="$(printf '%s\n' "$line" | awk '{print $2}')"
                fp="$(printf '%s\n' "$line" | "$SSH_KEYGEN" -lf - 2>/dev/null | awk '{print $2}')"
                [ -n "$fp" ] || continue
                printf 'fingerprint=%s type=%s\n' "$fp" "$type"
            done <<< "$scan"
            ;;
    esac
}

# ==================== bootstrap ====================
cmd_bootstrap() {
    local target="${1:-}"
    [ -n "$target" ] || die "bootstrap 需要 <target>"
    shift

    local want_fp="" method="copy-id" alias=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --fingerprint) want_fp="${2:-}"; shift 2 ;;
            --copy-id)     method="copy-id"; shift ;;
            --askpass)     method="askpass"; shift ;;
            --alias)       alias="${2:-}"; shift 2 ;;
            *) die "bootstrap 不认识的参数: $1" ;;
        esac
    done
    [ -n "$want_fp" ] || die "bootstrap 必须带 --fingerprint SHA256:...（先用 hostkey 扫描并把指纹念给用户确认）"
    [ -n "$SSH_KEYGEN" ] && [ -n "$SSH_KEYSCAN" ] || die "找不到 ssh-keygen / ssh-keyscan。"

    local host user port
    host="$(resolved "$target" host)"
    user="$(resolved "$target" user)"
    port="$(resolved "$target" port)"

    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true

    # --- 1. 钉死主机密钥 ---
    local scan
    scan="$("$SSH_KEYSCAN" -T 10 -p "$port" -t ed25519,ecdsa,rsa "$host" 2>/dev/null)" \
        || die "取不到 $host:$port 的主机密钥。"

    local match_line=""
    local line fp
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        fp="$(printf '%s\n' "$line" | "$SSH_KEYGEN" -lf - 2>/dev/null | awk '{print $2}')"
        if [ "$fp" = "$want_fp" ]; then match_line="$line"; break; fi
    done <<< "$scan"
    [ -n "$match_line" ] || die "指纹不匹配：$want_fp 不在 $host:$port 当前提供的主机密钥里。可能是地址填错，或存在中间人。停下来核对。"

    local lookup="$host"
    [ "$port" = "22" ] || lookup="[$host]:$port"
    if [ -f "$HAO_KNOWN_HOSTS" ] && "$SSH_KEYGEN" -F "$lookup" -f "$HAO_KNOWN_HOSTS" >/dev/null 2>&1; then
        # 已有该主机的记录；如果恰好是这把钥匙就是幂等重跑，否则是硬失败。
        if "$SSH_KEYGEN" -F "$lookup" -f "$HAO_KNOWN_HOSTS" 2>/dev/null | grep -qF "$(printf '%s' "$match_line" | awk '{print $2" "$3}')"; then
            note "主机密钥已在 $HAO_KNOWN_HOSTS 中，保持原样。"
        else
            die "$host 在 $HAO_KNOWN_HOSTS 里已有另一把主机密钥。主机密钥变更意味着重装过系统或有人冒充，必须先查清。"
        fi
    else
        ( umask 077; printf '%s\n' "$match_line" >> "$HAO_KNOWN_HOSTS" )
        note "已把主机密钥写入 $HAO_KNOWN_HOSTS。"
    fi

    # --- 2. 专用密钥：不存在才生成，存在则原样复用 ---
    local key_created="no"
    if [ ! -f "$HAO_KEY" ]; then
        mkdir -p "$(dirname "$HAO_KEY")"
        chmod 700 "$(dirname "$HAO_KEY")" 2>/dev/null || true
        # 空口令是刻意的：本机 ssh-agent 未必在运行，带口令会让每次新会话都需要人工介入。
        # 原生 ssh-keygen.exe 不认 /c/Users/... 这种 MSYS 路径，必须给 Windows 形式。
        "$SSH_KEYGEN" -q -t ed25519 -N '' -C 'hao-remote' -f "$(win_path "$HAO_KEY")"
        key_created="yes"
        note "已生成专用密钥 $HAO_KEY（空口令）。私钥不要外传。"
    else
        note "复用已有专用密钥 $HAO_KEY。"
    fi
    [ -f "$HAO_KEY.pub" ] || die "缺少 $HAO_KEY.pub。"

    # --- 3. 安装公钥 ---
    case "$method" in
        copy-id)
            bootstrap_copy_id "$host" "$port" "$user" ;;
        askpass)
            bootstrap_askpass "$host" "$port" "$user" || exit $?
            ;;
    esac

    # --- 4. 仅密钥登录验证 ---
    ssh_run "$user@$host" "$port" 'true' 2>/dev/null \
        || die "仅密钥登录验证失败。检查服务器 sshd 是否允许 PubkeyAuthentication。"
    note "仅密钥登录验证通过。"

    # --- 5. 地址形式才写 ssh config；别名已存在，不重复添加 ---
    if [ "$(resolved "$target" mode)" = "address" ]; then
        local name="$alias"
        [ -n "$name" ] || name="hao-$(printf '%s' "$host" | tr '.' '-')"
        add_config_entry "$name" "$host" "$port" "$user"
        note "已在 $(ssh_config_file) 登记别名 '$name'。"
    fi

    # --- 6. 登记目标 ---
    local key_sha now
    key_sha="$("$SSH_KEYGEN" -lf "$HAO_KEY.pub" 2>/dev/null | awk '{print $2}')"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -f "$TARGETS_TSV" ]; then
        grep -v "^$(target_key "$target")	" "$TARGETS_TSV" > "$TARGETS_TSV.tmp" || true
        mv "$TARGETS_TSV.tmp" "$TARGETS_TSV"
    fi
    printf '%s\t%s\t%s@%s:%s\t%s\t%s\n' \
        "$(target_key "$target")" "$target" "$user" "$host" "$port" "$key_sha" "$now" >> "$TARGETS_TSV"
    chmod 600 "$TARGETS_TSV"

    printf 'target=%s\nhost=%s\nuser=%s\nport=%s\nhostkey=%s\nkey=%s\nkey_created=%s\n' \
        "$target" "$host" "$user" "$port" "$want_fp" "$HAO_KEY" "$key_created"
}

# 默认路径：用户在终端里跑一次。密码由 ssh 自己从 tty 读，HAO 不接触。
bootstrap_copy_id() {
    local host="$1" port="$2" user="$3"
    local port_arg=""
    [ "$port" = "22" ] || port_arg="-p $port"
    note "请在你自己的终端里执行下面这条命令（按提示输入一次密码）："
    printf '\n    %s -i %s.pub %s -o PreferredAuthentications=password \\\n' \
        "${SSH_COPY_ID:-ssh-copy-id}" "$HAO_KEY" "$port_arg" >&2
    printf '        -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s %s@%s\n\n' \
        "$HAO_KNOWN_HOSTS" "$user" "$host" >&2

    if ! ssh_run "$user@$host" "$port" 'true' 2>/dev/null; then
        die "公钥尚未生效。执行上面的 ssh-copy-id 后重跑 bootstrap，或改用 --askpass。"
    fi
    note "检测到公钥已生效。"
}

# 密码文件的可读范围检查。
# Windows 上 Git Bash 的 chmod 是假的：NTFS 上新建文件永远 stat 成 644，
# 连用户现有的私钥也一样。真正决定谁能读的是 ACL，所以这里两种机制都查。
check_secret_file_perms() {
    local f="$1"
    if is_windows_shell && command -v icacls >/dev/null 2>&1; then
        local acl
        acl="$(icacls "$(win_path "$f")" 2>/dev/null || true)"
        [ -n "$acl" ] || return 0
        # 除 SYSTEM / Administrators / 当前用户之外，不应有其它授权项。
        # 这里只在出现 Everyone / Users / Authenticated Users 这类宽泛组时拒绝。
        if printf '%s\n' "$acl" | grep -Eiq ':(\([^)]*\))*(F|M|R)[^)]*\\\\(Everyone|Users|Authenticated Users|INTERACTIVE|CERTIFICATE SERVICE)'; then
            die "$f 的访问控制允许本机其他用户读取，里面是密码。请先执行：
    icacls \"$(win_path "$f")\" /inheritance:r /grant:r \"%USERNAME%:F\""
        fi
        return 0
    fi

    local mode
    mode="$(stat -c '%a' "$f" 2>/dev/null || echo '')"
    case "$mode" in
        600|400) ;;
        *) die "$f 权限是 ${mode:-未知}，必须是 0600。对同机其他用户可读等于已泄露。执行：chmod 600 $f" ;;
    esac
}

# 可选路径：密码放在用户自建的 0600 文件里，只把路径交给垫片。
# Windows 的 ssh.exe 用 CreateProcess 启动 askpass，.sh 不能直接执行，所以用 .cmd。
bootstrap_askpass() {
    local host="$1" port="$2" user="$3"
    local pwfile="${HAO_PASS_FILE:-$HOME/.ssh/hao_bootstrap.pw}"

    [ -f "$pwfile" ] || die "缺少密码文件 $pwfile。请先自己创建（chmod 600），内容为一次登录密码。"
    check_secret_file_perms "$pwfile"

    mkdir -p "$STATE_DIR"
    # shellcheck disable=SC2016
    printf '@echo off\r\ntype "%%HAO_ASKPASS_FILE%%"\r\n' > "$ASKPASS_CMD"
    chmod 600 "$ASKPASS_CMD"

    note "用 askpass 完成一次密码登录并安装公钥……"

    # 公钥从 stdin 进；密码文件只以路径形式出现在环境变量里。
    env SSH_ASKPASS="$(win_path "$ASKPASS_CMD")" \
        SSH_ASKPASS_REQUIRE=force \
        DISPLAY=:0 \
        HAO_ASKPASS_FILE="$(win_path "$pwfile")" \
        "$SSH_BIN" -o BatchMode=no -o PubkeyAuthentication=no \
            -o PreferredAuthentications=password,keyboard-interactive \
            -o NumberOfPasswordPrompts=1 \
            -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$(win_path "$HAO_KNOWN_HOSTS")" \
            -o ConnectTimeout=15 -o LogLevel=ERROR \
            -p "$port" "$user@$host" \
            'umask 077; mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys;
             k="$(cat)"; grep -qxF "$k" ~/.ssh/authorized_keys || printf "%s\n" "$k" >> ~/.ssh/authorized_keys' \
            < "$HAO_KEY.pub" \
        || die "密码登录失败。若服务器禁用了密码认证（PasswordAuthentication no），请改用云厂商控制台的密钥注入。"

    rm -f "$pwfile" "$ASKPASS_CMD"
    note "密码文件已删除。"
}

# 幂等地往 ssh config 追加一个带标记的 Host 块。
add_config_entry() {
    local name="$1" host="$2" port="$3" user="$4"
    local cfg begin end
    cfg="$(ssh_config_file)"
    begin="# >>> hao-remote $name >>>"
    end="# <<< hao-remote $name <<<"
    mkdir -p "$(dirname "$cfg")"

    if [ -f "$cfg" ] && grep -qF "$begin" "$cfg"; then
        note "别名 '$name' 的配置块已存在，保持原样。"
        return 0
    fi

    # 已有 Host 行能匹配这个别名或这个地址时，追加会让解析结果变得不可预测。
    if [ -f "$cfg" ] && grep -Eq "^[[:space:]]*Host[[:space:]]+.*[[:space:]]${name}([[:space:]]|$)|^[[:space:]]*Host[[:space:]]+${name}([[:space:]]|$)" "$cfg"; then
        die "ssh config 里已有 Host '$name'，不覆盖。请换一个 --alias。"
    fi
    if [ -f "$cfg" ] && grep -Eq "^[[:space:]]*HostName[[:space:]]+${host//./\\.}[[:space:]]*$" "$cfg"; then
        die "ssh config 里已有指向 $host 的条目，不重复添加。请直接用那个别名。"
    fi

    [ -f "$cfg" ] && cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d_%H%M%S)"
    {
        printf '\n%s\n' "$begin"
        printf 'Host %s\n' "$name"
        printf '  HostName %s\n' "$host"
        [ "$port" = "22" ] || printf '  Port %s\n' "$port"
        printf '  User %s\n' "$user"
        # 写 ~/ 相对形式：ssh config 里 ~ 由每个客户端自己展开，
        # 原生的 ssh.exe 和 Git Bash 的 ssh 都认；写死 /c/Users/... 只有前者认。
        printf '  IdentityFile %s\n' "${HAO_KEY/#$HOME/~}"
        printf '  IdentitiesOnly yes\n'
        printf '%s\n' "$end"
    } >> "$cfg"
}

# ==================== probe ====================
# 只读：这台机器是谁、是什么系统、能不能提权。输出 key=value 供 agent 判断与回显。
cmd_probe() {
    local target="${1:-}"
    [ -n "$target" ] || die "probe 需要 <target>"

    local host user port
    host="$(resolved "$target" host)"
    user="$(resolved "$target" user)"
    port="$(resolved "$target" port)"

    local probe_file rc=0
    probe_file="$(mktemp)"
    cat > "$probe_file" <<'__HAO_PROBE__'
uid="$(id -u 2>/dev/null || echo unknown)"
login_user="$(id -un 2>/dev/null || echo unknown)"
hostname_v="$(hostname 2>/dev/null || echo unknown)"
if [ -r /etc/os-release ]; then
    os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"' | head -1)"
    os_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"' | head -1)"
else
    os_id=unknown; os_version=unknown
fi
case "$os_id $os_version" in
    "debian 13"|"debian 12"|"ubuntu 26.04"|"ubuntu 24.04"|"ubuntu 22.04") supported=yes ;;
    *) supported=no ;;
esac
if [ "$uid" = "0" ]; then
    sudo_state=n/a
elif sudo -n true >/dev/null 2>&1; then
    sudo_state=yes
else
    sudo_state=no
fi
if command -v curl >/dev/null 2>&1; then
    public_ip="$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || echo unknown)"
elif command -v wget >/dev/null 2>&1; then
    public_ip="$(wget -qO- -T 5 https://api.ipify.org 2>/dev/null || echo unknown)"
else
    public_ip=unknown
fi
[ -n "$public_ip" ] || public_ip=unknown
if command -v sshd >/dev/null 2>&1 && sshd -T >/dev/null 2>&1; then
    sshd_ports="$(sshd -T 2>/dev/null | awk '$1=="port"{printf "%s%s", sep, $2; sep=","}')"
elif [ -r /etc/ssh/sshd_config ]; then
    sshd_ports="$(awk 'tolower($1)=="port"{printf "%s%s", sep, $2; sep=","}' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)"
else
    sshd_ports=unknown
fi
[ -n "$sshd_ports" ] || sshd_ports=unknown
if [ -d /var/lib/hao ]; then state_dir=present; else state_dir=absent; fi
machine_id="$(cat /etc/machine-id 2>/dev/null || echo unknown)"
printf 'uid=%s\nlogin_user=%s\nhostname=%s\nos_id=%s\nos_version=%s\nos_supported=%s\n' \
    "$uid" "$login_user" "$hostname_v" "$os_id" "$os_version" "$supported"
printf 'sudo_nopasswd=%s\npublic_ip=%s\nsshd_ports=%s\nstate_dir=%s\nmachine_id=%s\n' \
    "$sudo_state" "$public_ip" "$sshd_ports" "$state_dir" "$machine_id"
__HAO_PROBE__

    local out
    out="$(ssh_run "$user@$host" "$port" 'sh -s' "$probe_file")" || rc=$?
    rm -f "$probe_file"
    [ $rc -eq 0 ] || die "probe 连接失败（不可达、认证失败，或登录用户无权读取所需信息）。"

    local identity
    identity="$(printf '%s\n' "$out" | grep -E '^(machine_id|public_ip)=' | sort | sha256sum | cut -c1-16)"
    printf '%s\n' "$out"
    printf 'identity=%s\n' "$identity"

    local tdir
    tdir="$(target_dir "$target")"
    mkdir -p "$tdir"; chmod 700 "$tdir" 2>/dev/null || true
    printf 'HAO_IDENTITY=%q\n' "$identity" > "$tdir/identity.env"
    chmod 600 "$tdir/identity.env"
}

# ==================== bundle ====================
# 把 scripts/ + templates/ 归一化后复制进 staging。CRLF 必须在这一步去掉。
build_bundle_into() {
    local staging="$1"
    mkdir -p "$staging/scripts" "$staging/templates"
    local f rel
    for f in "$SKILL_SRC"/scripts/*.sh; do
        rel="scripts/$(basename "$f")"
        # 统一成 LF：本机工作区可能是 CRLF，而 "set -euo pipefail\r" 在 Linux 上
        # 直接报非法选项；shebang 带 \r 则报 "No such file or directory"。
        sed 's/\r$//' "$f" > "$staging/$rel"
        chmod 0755 "$staging/$rel"
    done
    for f in "$SKILL_SRC"/templates/*; do
        [ -f "$f" ] || continue
        rel="templates/$(basename "$f")"
        sed 's/\r$//' "$f" > "$staging/$rel"
        chmod 0644 "$staging/$rel"
    done
}

# 填充 staging 并返回完整树哈希，同时写下 .hao-session。
build_bundle() {
    local staging="$1" tree
    build_bundle_into "$staging"
    tree="$(tree_hash "$staging")"
    printf 'bundle_sha256=%s\n' "$tree" > "$staging/.hao-session"
    printf '%s' "$tree"
}

# 计算一个目录下 scripts/ 与 templates/ 的稳定树哈希。
# 输出只有哈希值，路径和分隔符不参与，避免跨平台格式差异。
tree_hash() {
    local dir="$1"
    # 最后一步必须把哈希列表写进文件再哈希，不能直接管道。
    # MSYS 的 sha256sum 对管道输入写 "hash *-"，GNU/Linux 写 "hash  -"，
    # 这一列也会进哈希，导致两边永远不相等。读文件时两边格式一致。
    # LC_ALL=C 是必须的：MSYS 的 sort 按 Windows 区域规则排，GNU/Linux 按
    # 字节序排，"-" 和 "." 的相对权重不同（实测 fail2ban-nginx-scan.conf 与
    # fail2ban-nginx.local 顺序相反），文件顺序一漂哈希就永远对不上。
    ( cd "$dir" || return 1
      local listing
      listing="$(mktemp)"
      find scripts templates -type f -print0 | LC_ALL=C sort -z | \
          xargs -0 sha256sum | awk '{print $1}' > "$listing"
      # 用重定向而不是文件参数：文件名（随机的 mktemp 路径）不能进哈希。
      sha256sum < "$listing" | awk '{print $1}'
      rm -f "$listing" )
}

# 非 root 目标用 sudo -n；不可用就停下，不改 sudoers。
detect_sudo() {
    local host="$1" port="$2" user="$3"
    local uid
    uid="$(ssh_run "$user@$host" "$port" 'id -u' | tr -d '\r')" || die "无法连接 $user@$host:$port。"
    if [ "$uid" = "0" ]; then printf '0'; return 0; fi
    if ssh_run "$user@$host" "$port" 'sudo -n true' >/dev/null 2>&1; then
        printf '1'
    else
        die "目标用户 '$user' 不是 root，且 sudo -n 不可用。HAO 需要 root 才能装包和写 /etc。"
    fi
}

cmd_push() {
    local target="${1:-}"
    [ -n "$target" ] || die "push 需要 <target>"

    local host user port use_sudo
    host="$(resolved "$target" host)"
    user="$(resolved "$target" user)"
    port="$(resolved "$target" port)"
    use_sudo="$(detect_sudo "$host" "$port" "$user")"

    local staging tree
    staging="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$staging'" EXIT
    tree="$(build_bundle "$staging")"

    local remote_dir
    remote_dir="$(ssh_run "$user@$host" "$port" 'mktemp -d /tmp/hao.XXXXXXXXXX')" \
        || die "无法在远端创建临时目录。"
    remote_dir="${remote_dir%$'\r'}"
    [ -n "$remote_dir" ] || die "远端没有返回临时目录路径。"

    local tdir
    tdir="$(target_dir "$target")"
    mkdir -p "$tdir"; chmod 700 "$tdir" 2>/dev/null || true

    local bundle_file
    bundle_file="$(mktemp)"
    ( cd "$staging" && tar -czf "$bundle_file" scripts templates .hao-session ) \
        || die "本地打包失败。"
    tar -tzf "$bundle_file" >/dev/null || die "本地打包结果损坏。"

    local extract_cmd
    # --warning=no-timestamp：Windows 与服务器的时钟有几百毫秒偏差时，
    # tar 会为每个文件打一行 "time stamp in the future"，把真正的错误淹掉。
    extract_cmd="tar --warning=no-timestamp -xzf - -C $(shq "$remote_dir")"
    [ "$use_sudo" = "1" ] && extract_cmd="sudo -n $extract_cmd"
    ssh_run "$user@$host" "$port" "$extract_cmd" "$bundle_file" \
        || { rm -f "$bundle_file"; die "bundle 上传失败。"; }
    rm -f "$bundle_file"

    # 落地门禁：三个脚本能解析、没有残留 CR、树哈希与客户端一致。
    # 任何一条不过都不启用这个目录 —— 半坏脚本报出来的错会指向毫不相关的地方。
    local gate_cmd
    gate_cmd="cd $(shq "$remote_dir") || exit 1
for s in scripts/*.sh; do bash -n \"\$s\" || exit 1; done
if grep -rlU \$'\\r' scripts templates; then echo 'CR found' >&2; exit 2; fi
l=\$(mktemp); find scripts templates -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | awk '{print \$1}' > \"\$l\"; LC_ALL=C sha256sum < \"\$l\" | awk '{print \$1}'; rm -f \"\$l\""
    [ "$use_sudo" = "1" ] && gate_cmd="sudo -n bash -c $(shq "$gate_cmd")"

    local remote_tree
    remote_tree="$(ssh_run "$user@$host" "$port" "$gate_cmd" | tr -d '\r')" \
        || die "远端门禁失败（bash -n 或 CR 检查未通过），已上传的目录不可用。"

    [ "$remote_tree" = "$tree" ] || die "树哈希不一致：本地 $tree，远端 $remote_tree。上传不完整。"

    {
        printf 'HAO_TARGET=%q\n' "$target"
        printf 'HAO_HOST=%q\n' "$host"
        printf 'HAO_PORT=%q\n' "$port"
        printf 'HAO_USER=%q\n' "$user"
        printf 'HAO_REMOTE_DIR=%q\n' "$remote_dir"
        # 存前 12 位，和 bundle_hash() 的返回值对齐。完整哈希在 push 的输出里。
        printf 'HAO_BUNDLE=%q\n' "${tree:0:12}"
        printf 'HAO_SUDO=%q\n' "$use_sudo"
    } > "$tdir/session.env"
    chmod 600 "$tdir/session.env"

    printf 'remote_dir=%s\nbundle_sha256=%s\n' "$remote_dir" "$tree"
}

load_session() {
    local tdir
    tdir="$(target_dir "$1")"
    [ -f "$tdir/session.env" ] || return 1
    # shellcheck disable=SC1090,SC1091
    . "$tdir/session.env"
}

# ==================== session ====================
# 建立可复用的远端目录，路径单独打到 stdout；进度走 stderr，
# 所以 SKILL="$(hao-remote.sh session "$T")" 不会被污染。
cmd_session() {
    local target="${1:-}"
    [ -n "$target" ] || die "session 需要 <target>"

    local tdir
    tdir="$(target_dir "$target")"

    if load_session "$target"; then
        if [ "${HAO_BUNDLE:-}" = "$(bundle_hash)" ] && [ -n "${HAO_REMOTE_DIR:-}" ]; then
            # /tmp 是 tmpfs，重启会清掉，所以要真的验一次。
            if ssh_run "$HAO_USER@$HAO_HOST" "$HAO_PORT" \
                    "test -f $(shq "$HAO_REMOTE_DIR")/.hao-session" >/dev/null 2>&1; then
                printf '%s' "$HAO_REMOTE_DIR"
                return 0
            fi
            note "远端会话目录已不存在（可能重启过），重新推送。"
        fi
    fi

    cmd_push "$target" >&2
    load_session "$target" || die "内部错误：push 之后仍读不到会话。"
    printf '%s' "$HAO_REMOTE_DIR"
}

# 「当前源头对应哪个 bundle」的快捷指纹。只用来判断会话目录是否还能复用，
# 所以取 tree_hash 的前 12 位就够；但必须和 push 用同一套算法，
# 否则会话会误判「内容没变」而复用一份旧文件。
bundle_hash() {
    local staged
    staged="$(mktemp -d)"
    build_bundle_into "$staged" >/dev/null
    tree_hash "$staged" | cut -c1-12
    rm -rf "$staged"
}

# ==================== exec ====================
cmd_exec() {
    local target="${1:-}"
    [ -n "$target" ] || die "exec 需要 <target>"
    shift

    local want_tty=0
    if [ "${1:-}" = "--tty" ]; then want_tty=1; shift; fi
    [ "${1:-}" = "--" ] && shift

    load_session "$target" || die "目标 '$target' 还没有会话。先运行: hao-remote.sh session $target"

    # 覆盖 build_ssh_opts 里的 RequestTTY=no：后面的 -o 优先。
    local -a extra=()
    [ "$want_tty" = 1 ] && extra=('-o' 'RequestTTY=force')

    local sudo_prefix=""
    [ "${HAO_SUDO:-0}" = "1" ] && sudo_prefix="sudo -n "
    local prelude
    prelude="export SKILL=$(shq "$HAO_REMOTE_DIR"); cd $(shq "$HAO_REMOTE_DIR") || exit 1; "

    if [ "${1:-}" = "-" ]; then
        # 脚本从 stdin 直通远端 bash -s：多行、嵌套 heredoc、trap 都保持原样，
        # 内容不进任何一侧的 argv。退出码原样返回。
        ssh_run "$HAO_USER@$HAO_HOST" "$HAO_PORT" \
            "${sudo_prefix}bash -c $(shq "${prelude}exec bash -s")" \
            "" ${extra[@]+"${extra[@]}"}
        return $?
    fi

    [ $# -gt 0 ] || die "exec 需要一个命令，或 '-' 表示从 stdin 读脚本"

    # 以本地 skill 目录开头的路径翻译成远端路径，这样
    # "$SKILL/templates/nginx-htpasswd.conf" 在远端仍指向同一份内容。
    local -a translated=()
    local a
    for a in "$@"; do
        case "$a" in
            "$SKILL_SRC"*) a="$HAO_REMOTE_DIR${a#"$SKILL_SRC"}" ;;
        esac
        translated+=("$a")
    done
    # 两种用法：
    #   exec <target> -- cmd arg1 arg2      直接执行，不经过远端 shell 解析
    #   exec <target> -- 'a | b > c'        单参数里含 shell 元字符时按脚本执行
    # 后者是 ergonomics：references 里有大量管道和重定向，一个参数整串传下来
    # 是最自然的写法。判断依据是「只有一个参数且含 shell 元字符」。
    local remote_body
    if [ $# -eq 1 ] && printf '%s' "$1" | grep -qE '[|&;<>()$`]'; then
        remote_body="$1"
    else
        local quoted
        quoted="$(printf '%q ' "${translated[@]}")"
        remote_body="$quoted"
    fi
    ssh_run "$HAO_USER@$HAO_HOST" "$HAO_PORT" \
        "${sudo_prefix}bash -c $(shq "${prelude}${remote_body}")" \
        "" ${extra[@]+"${extra[@]}"}
}

# ==================== cleanup ====================
cmd_cleanup() {
    local target="${1:-}"
    [ -n "$target" ] || die "cleanup 需要 <target>"
    shift || true
    local all=0
    [ "${1:-}" = "--all" ] && all=1

    load_session "$target" || { note "没有登记到会话，无需清理。"; return 0; }

    # 只删我们自己的目录：有标记、非符号链接、属主正确。
    local stmt
    stmt="target=$(shq "$HAO_REMOTE_DIR")
[ -n \"\$target\" ] || exit 0
[ -L \"\$target\" ] && { echo 'refuse: symlink' >&2; exit 3; }
[ -d \"\$target\" ] || exit 0
[ -f \"\$target/.hao-session\" ] || { echo 'refuse: no marker' >&2; exit 3; }
[ \"\$(stat -c %u \"\$target\")\" = \"\$(id -u)\" ] || { echo 'refuse: owner' >&2; exit 3; }
rm -rf \"\$target\"
echo \"removed=\$target\""

    ssh_run "$HAO_USER@$HAO_HOST" "$HAO_PORT" "$stmt" \
        || die "cleanup 未执行：远端目录没通过标记/属主/符号链接检查。"

    rm -f "$(target_dir "$target")/session.env"
    note "已清理 $HAO_REMOTE_DIR"

    if [ "$all" = 1 ]; then
        ssh_run "$HAO_USER@$HAO_HOST" "$HAO_PORT" \
            'find /tmp -maxdepth 1 -type d -name "hao.*" -user "$(id -un)" -mtime +0 -exec rm -rf {} + 2>/dev/null || true' \
            >&2 || true
    fi
}

# ==================== targets ====================
cmd_targets() {
    if [ ! -s "$TARGETS_TSV" ]; then
        echo "（还没有登记任何服务器。用 bootstrap 连接第一台。）"
        return 0
    fi
    printf '%-20s %-28s %-8s %s\n' TARGET DEST PORT LAST_SEEN
    local _key tgt dest _key_sha ts
    while IFS=$'\t' read -r _key tgt dest _key_sha ts; do
        [ -n "$tgt" ] || continue
        printf '%-20s %-28s %-8s %s\n' "$tgt" "$dest" "" "$ts"
    done < "$TARGETS_TSV" 2>/dev/null || true
}

# ==================== 分派 ====================
usage() {
    awk 'NR <= 2 { next }
         /^[[:space:]]*$/ { print ""; next }
         /^#/ { sub(/^# ?/, ""); print; next }
         { exit }' "${BASH_SOURCE[0]}"
}

# --port 可以出现在任意位置：hao-remote.sh probe --port 46868 root@1.2.3.4
# ssh config 里没有条目时 ssh -G 只会给出 22，而 VPS 用高位端口很常见。
# 在分派前从 $@ 里摘掉，剩下的按原顺序交给子命令。
PORT_OVERRIDE=""
_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --port|-p)
            PORT_OVERRIDE="${2:-}"
            [ -n "$PORT_OVERRIDE" ] || die "--port 需要一个值"
            shift 2 ;;
        *) _args+=("$1"); shift ;;
    esac
done
set -- ${_args[@]+"${_args[@]}"}

case "${1:-}" in
    resolve)   shift; cmd_resolve "$@" ;;
    hostkey)   shift; cmd_hostkey "$@" ;;
    bootstrap) shift; cmd_bootstrap "$@" ;;
    probe)     shift; cmd_probe "$@" ;;
    session)   shift; cmd_session "$@" ;;
    push)      shift; cmd_push "$@" ;;
    exec)      shift; cmd_exec "$@" ;;
    cleanup)   shift; cmd_cleanup "$@" ;;
    targets)   shift; cmd_targets "$@" ;;
    -h|--help|"") usage ;;
    *) die "未知子命令: $1（可用: resolve hostkey bootstrap probe session push exec cleanup targets）" ;;
esac
