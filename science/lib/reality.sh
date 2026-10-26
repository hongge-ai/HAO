# shellcheck shell=bash
#
# science/lib/reality.sh —— 工具一：VLESS + XTLS-Vision + Reality 入站。
#
# 特点：不需要域名、不需要证书。Reality 借用一个真实站点（默认 www.bing.com）
# 的 TLS 握手特征做伪装，被主动探测时把流量原样转给那个站点，探测者看到的是
# 对方的真实证书。代价是只有支持 Reality 的客户端能连（v2rayN / v2rayNG /
# Shadowrocket / sing-box / Mihomo），填不进「系统代理」那种地方。
#
# 默认目标在 2026-10 通过了真实 Reality 握手与代理请求。选目标不能只看可达性：
# 目标的 Certificate 记录超过 Reality 预读上限时，TLS 1.3 站点也会握手失败。

REALITY_SERVICE="xray-reality"
REALITY_FRAGMENT_NAME="10-reality.json"
REALITY_PORT_DEFAULT=443
REALITY_SNI_DEFAULT="www.bing.com"

reality_usage() {
    cat >&2 <<'EOF'
用法: sudo ./install.sh reality [选项]

选项:
  --port PORT       监听端口（默认 443）
  --sni DOMAIN      伪装目标站点（默认 www.bing.com），必须是真实可达的 HTTPS 站点
  --rotate-keys     重新生成密钥与 UUID。**现有客户端全部失效**，默认不这么做
  -h, --help        显示本帮助

重跑是安全的：默认复用已有的密钥和 UUID，不会让现有客户端掉线。
EOF
}

# 生成或复用 Reality 凭据。第一个参数为 true 时强制轮换。
#
# 密钥值全程不进 argv、不进 stdout：xray 的输出先落到 0700 临时目录里的文件，
# 再用 hao-secret.sh 的 KEY=@file:PATH 收进凭据文件。
#
# 公钥在**生成时**就一起存下来，这样重跑永远不需要 `xray x25519 -i <私钥>` ——
# 那条命令会把私钥放进命令行参数，同机任何用户都能从 /proc/<pid>/cmdline 读到。
reality_ensure_credentials() {
    local rotate="${1:-false}"
    local credfile tmpdir keyout need_generate=false k f
    credfile="$(cred_file "$REALITY_SERVICE")"

    if [ "$rotate" = true ]; then
        need_generate=true
    else
        for k in PRIVATE_KEY PUBLIC_KEY UUID SHORT_ID; do
            secret has "$credfile" "$k" || { need_generate=true; break; }
        done
    fi

    if [ "$need_generate" = false ]; then
        log_info "复用现有凭据（$credfile），现有客户端不受影响"
        return 0
    fi

    if [ "$rotate" = true ] && [ -f "$credfile" ]; then
        log_warning "将重新生成密钥与 UUID —— 所有现有客户端配置都会失效"
        confirm "确认轮换？" || die "已取消"
    fi

    tmpdir="$(make_tmpdir)"
    # shellcheck disable=SC2064  # 立即展开：函数返回后局部变量就没了
    trap "rm -rf '$tmpdir'" RETURN

    # 临时目录是 0700 且属 root，里面的文件靠目录权限保护，不必再动 umask。
    keyout="$tmpdir/keys"
    "$XRAY_BIN" x25519 > "$keyout" || die "生成 X25519 密钥对失败"

    # xray x25519 的输出形如：
    #   PrivateKey: <base64url>
    #   Password (PublicKey): <base64url>
    #   Hash32: <base64url>
    awk '/^PrivateKey:/ { print $NF }' "$keyout" > "$tmpdir/private" || true
    awk '/^Password \(PublicKey\):/ { print $NF }' "$keyout" > "$tmpdir/public" || true
    cat /proc/sys/kernel/random/uuid > "$tmpdir/uuid" 2>/dev/null \
        || "$XRAY_BIN" uuid > "$tmpdir/uuid"
    openssl rand -hex 8 > "$tmpdir/shortid"

    for f in private public uuid shortid; do
        [ -s "$tmpdir/$f" ] \
            || die "凭据生成失败（$f 为空）—— xray x25519 的输出格式可能变了，检查 $XRAY_BIN x25519"
    done

    local -a specs=(
        "PRIVATE_KEY=@file:$tmpdir/private"
        "PUBLIC_KEY=@file:$tmpdir/public"
        "UUID=@file:$tmpdir/uuid"
        "SHORT_ID=@file:$tmpdir/shortid"
    )
    if [ "$rotate" = true ]; then
        secret write "$credfile" "${specs[@]}" --rotate PRIVATE_KEY,PUBLIC_KEY,UUID,SHORT_ID
    else
        secret write "$credfile" "${specs[@]}"
    fi
}

# reality_write_fragment <端口> <伪装域名>
reality_write_fragment() {
    local port="$1" sni="$2"
    local target="$XRAY_CONF_DIR/$REALITY_FRAGMENT_NAME"
    local credfile tmpdir staged
    credfile="$(cred_file "$REALITY_SERVICE")"

    case "$(guard managed-file "$target")" in
        missing|"managed "*) ;;
        *) die "$target 存在但不是本工具写的，不覆盖。" ;;
    esac

    tmpdir="$(make_tmpdir)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN
    staged="$tmpdir/fragment.json"

    # 两段渲染：非密钥占位符先替换，密钥交给 hao-secret.sh render 注入。
    # 不要「读出密钥再拼字符串」——那等于把值搬进 shell 变量和进程环境。
    render_plain "10-reality.json.tmpl" "$staged" 0600 \
        "PORT=$port" \
        "DEST_SNI=$sni"

    secret render "$staged" "$target" --from "$credfile" --mode 0600
    assert_no_tokens "$target"
    log_success "已写入 $target (0600)——含私钥，不要 cat 它"
}

# reality_write_client_info <端口> <伪装域名>
reality_write_client_info() {
    local port="$1" sni="$2"
    local outfile credfile tmpdir staged server_ip
    outfile="$(client_file "$REALITY_SERVICE")"
    credfile="$(cred_file "$REALITY_SERVICE")"

    server_ip="$(detect_server_ip)"
    [ -n "$server_ip" ] || log_warning "取不到公网 IP，客户端信息里的地址需要你自己填"

    tmpdir="$(make_tmpdir)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN
    staged="$tmpdir/client.txt"

    render_plain "reality-client.txt.tmpl" "$staged" 0600 \
        "SERVER_IP=${server_ip:-填服务器公网IP}" \
        "PORT=$port" \
        "DEST_SNI=$sni" \
        "NODE_NAME=reality-$port" \
        "GENERATED_AT=$(date -u '+%Y-%m-%d %H:%M:%SZ')"

    secret render "$staged" "$outfile" --from "$credfile" --mode 0600
    assert_no_tokens "$outfile"

    # 分享链接必须成形，否则用户导入时只看到「解析失败」而不知道原因。
    # grep -q 不打印内容，不会把 UUID 带到终端。
    grep -qE '^vless://[^@]+@[^:]+:[0-9]+\?' "$outfile" \
        || die "$outfile 里的分享链接格式不对——模板占位符出问题了"
    log_success "客户端参数已写入 $outfile (0600)"
}

cmd_reality() {
    local rotate_keys=false
    local port="$REALITY_PORT_DEFAULT"
    local sni="$REALITY_SNI_DEFAULT"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --port) [ -n "${2:-}" ] || die "--port 需要一个端口号"; port="$2"; shift 2 ;;
            --sni)  [ -n "${2:-}" ] || die "--sni 需要一个域名";     sni="$2";  shift 2 ;;
            --rotate-keys) rotate_keys=true; shift ;;
            -h|--help) reality_usage; return 0 ;;
            *) reality_usage; die "未知参数: $1" ;;
        esac
    done

    validate_port "$port"
    validate_domain "$sni"

    require_root
    require_skill_scripts
    require_os
    require_cmds curl openssl systemctl ss

    # ---- 只读检查 ----
    log_step "只读检查"
    require_port_for_xray "$port" "Reality 入站"

    # 伪装目标必须真的可达：连不上的 dest 会让主动探测立刻看穿这是个代理。
    # 不加 -f：这里只关心 TLS 握手成不成，HTTP 返回 403/302 都算正常。
    if curl -sS --max-time 8 -o /dev/null "https://$sni" 2>/dev/null; then
        log_success "伪装目标 $sni 可达"
    else
        log_warning "从这台机器连不上 https://$sni"
        log_warning "Reality 被主动探测时要把流量原样转给它，连不上就等于伪装失效。"
        confirm "仍然继续？" || die "已取消。换一个从本机可达的 HTTPS 站点（--sni）。"
    fi

    # ---- 讲清楚再动手 ----
    log_step "即将做的事"
    cat >&2 <<EOF
  1. 安装 xray-core 到 $XRAY_BIN，写 systemd 单元 $XRAY_UNIT（还没有的话）
  2. 写入站配置 $XRAY_CONF_DIR/$REALITY_FRAGMENT_NAME（0600，含私钥）
  3. 生成或复用凭据 $(cred_file "$REALITY_SERVICE")（0600，值不显示）
  4. 启用并启动 xray，监听 ${port}/TCP，伪装成 $sni
  5. 记录状态到 /var/lib/hao，服务名 $REALITY_SERVICE

  不会改：现有的 Nginx 配置、80 端口、其他入站配置。
EOF
    confirm "继续？" || die "已取消，什么都没改。"

    # ---- 执行 ----
    ensure_xray_core
    log_step "配置 Reality 入站"
    reality_ensure_credentials "$rotate_keys"
    reality_write_fragment "$port" "$sni"
    xray_apply "$port" \
        || die "配置已写入，但服务没能正常起来——如实汇报，不要当成成功。"
    reality_write_client_info "$port" "$sni"

    # ---- 记录状态 ----
    log_step "记录状态"
    state record "$REALITY_SERVICE" installed \
        "managed:$XRAY_CONF_DIR/$REALITY_FRAGMENT_NAME" \
        "secret:$(cred_file "$REALITY_SERVICE")" \
        "secret:$(client_file "$REALITY_SERVICE")"
    state intent "$REALITY_SERVICE" \
        protocol=vless-reality \
        port="$port" \
        sni="$sni" \
        flow=xtls-rprx-vision
    state handoff

    notice_firewall "$port"

    log_success "Reality 入站部署完成"
    cat >&2 <<EOF

  地址     $(detect_server_ip):$port
  伪装     $sni
  客户端   $(client_file "$REALITY_SERVICE")   ← 参数都在这个文件里（0600）

  客户端参数自己去那个文件里看（sudo cat），我不会把它打印出来。
  再把 /var/lib/hao/DEPLOY-INTENT.md 存一份到自己的笔记里——机器销毁后那是重建依据。
EOF
}
