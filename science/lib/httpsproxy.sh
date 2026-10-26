# shellcheck shell=bash
#
# science/lib/httpsproxy.sh —— 工具二：HTTPS 正向代理（用户名 + 口令）。
#
# 这就是别人给你「https 域名 端口 用户名 口令」时那种代理：一个 http 正向代理
# 入站，外面包一层 TLS，认证用 HTTP Basic。
#
# 和 Reality 的分工：
#   这个胜在**兼容**——任何能填「HTTPS 代理」的客户端都能用，不需要专门的翻墙软件。
#   Reality 胜在**抗封锁**——不要域名不要证书，主动探测看不出是代理。
# 一个明文特征明显的 TLS 代理端口被封的概率高于 Reality，所以两个都装、互为备份
# 是合理的做法。
#
# 硬性限制（必须告诉用户，不能让他自己撞）：
#   - HTTP 代理协议只转 TCP。UDP（QUIC、UDP 游戏、DNS over UDP）走不了。
#   - 「到代理走 TLS」这件事 git / pip / apt / 系统代理设置都不支持，
#     它们只认明文 HTTP 代理。

HTTPSPROXY_SERVICE="xray-httpsproxy"
HTTPSPROXY_FRAGMENT_NAME="20-httpsproxy.json"
HTTPSPROXY_PORT_DEFAULT=8443
HTTPSPROXY_USER_DEFAULT="proxy"
RENEWAL_HOOK="/etc/letsencrypt/renewal-hooks/deploy/restart-xray.sh"

httpsproxy_usage() {
    cat >&2 <<'EOF'
用法: sudo ./install.sh proxy --domain <域名> [选项]

必填:
  --domain DOMAIN        代理的域名，必须已经解析到这台机器（证书和客户端都用它）

选项:
  --port PORT            监听端口（默认 8443）
  --user NAME            用户名（默认 proxy）。改了会自动更新账号
  --email ADDR           Let's Encrypt 账户联系邮箱（可选）。不给就不注册联系方式；
                         **不会**替你从域名拼一个，那种地址通常并不存在
  --password-file PATH   口令取自这个文件的第一行（自带口令走这条）
  --password-env VAR     口令取自这个环境变量
  --rotate-password      重新生成随机口令（现有客户端要改配置）
  --selfsigned           跳过 Let's Encrypt，直接用自签名证书
                         （客户端必须能勾「跳过证书校验」，很多客户端没这个开关）
  -h, --help             显示本帮助

口令默认自动生成 32 位随机串，写进 /etc/hao/xray-httpsproxy.env（0600）。
**不要用 --password 这种命令行参数传口令**：命令行参数同机任何用户都能从 /proc 读到，
所以这个脚本压根没提供那个选项。

重跑是安全的：默认复用已有口令和证书，不会让现有客户端掉线。
EOF
}

# ==================== 只读检查 ====================
# 域名必须指向本机：不然证书签不下来，客户端也连不到。早停比签完再排查便宜。
httpsproxy_check_dns() {
    local domain="$1" resolved server_ip
    resolved="$(resolve_domain "$domain" | tr '\n' ' ')"
    server_ip="$(detect_server_ip)"

    if [ -z "${resolved// /}" ]; then
        log_error "$domain 解析不到任何 A 记录。"
        log_error "先去 DNS 那边加一条 A 记录指向 ${server_ip:-这台机器的公网 IP}，等生效后再来。"
        die "已停止，什么都没改。"
    fi
    if [ -n "$server_ip" ] && ! domain_points_here "$domain" "$server_ip"; then
        log_warning "$domain 解析到 $resolved，其中没有本机公网 IP $server_ip。"
        log_warning "常见原因：DNS 还没生效；或者用了 Cloudflare 橙云代理——"
        log_warning "橙云不代理 $PROXY_PORT 这类端口，必须把这条记录改成灰云（DNS only）。"
        confirm "仍然继续？（证书很可能签不下来）" || die "已停止，什么都没改。"
    else
        log_success "$domain 解析到 $resolved，包含本机 IP"
    fi
}

# ==================== 证书 ====================
# 结果通过四个全局变量传出：
#   CERT_KIND       给人看的一句话（会进客户端信息文件和收尾汇报）
#   CERT_STATE      给机器看的标签：letsencrypt / selfsigned / other
#                   —— intent 里记的是这个。以前那里用
#                   `[ "$CERT_KIND" = "Let's Encrypt" ] && … || echo selfsigned`
#                   去推，于是「用了别人签的现有证书」这一支被记成 selfsigned，
#                   换机器重放时会照着错的标签走。
#   CERT_FULLCHAIN / CERT_KEY   证书路径
httpsproxy_ensure_cert() {
    local domain="$1" want_selfsigned="$2"
    local le_dir="/etc/letsencrypt/live/$domain"
    local issuer

    if [ "$want_selfsigned" = true ]; then
        httpsproxy_selfsigned_cert "$domain"
        return 0
    fi

    issuer="$(guard cert-issuer "$le_dir/fullchain.pem")"
    case "$issuer" in
        letsencrypt)
            log_success "已有 Let's Encrypt 证书，跳过签发（幂等）"
            CERT_KIND="Let's Encrypt"
            CERT_STATE="letsencrypt"
            CERT_FULLCHAIN="$le_dir/fullchain.pem"
            CERT_KEY="$le_dir/privkey.pem"
            httpsproxy_install_renewal_hook
            return 0
            ;;
        selfsigned)
            log_info "现有的是自签名证书，尝试换成真证书"
            ;;
        missing)
            log_info "还没有证书，开始签发"
            ;;
        *)
            # 这个路径下已经有一张不是本流程签的证书。尊重它，不覆盖也不重签
            # （certbot 再签会新建一个 -0001 的 lineage，然后两张证书谁在续期都说不清）。
            log_warning "$le_dir/fullchain.pem 的颁发者是「$issuer」，不是本流程签的。"
            log_warning "直接用它，不覆盖、不重签。要换成 Let's Encrypt 请自己先处理掉那张证书。"
            CERT_KIND="现有证书（$issuer）"
            CERT_STATE="other"
            CERT_FULLCHAIN="$le_dir/fullchain.pem"
            CERT_KEY="$le_dir/privkey.pem"
            [ -f "$CERT_KEY" ] || die "$CERT_KEY 不存在，无法使用这张证书。停下来人工看一眼。"
            return 0
            ;;
    esac

    if httpsproxy_issue_letsencrypt "$domain"; then
        CERT_KIND="Let's Encrypt"
        CERT_STATE="letsencrypt"
        CERT_FULLCHAIN="$le_dir/fullchain.pem"
        CERT_KEY="$le_dir/privkey.pem"
        httpsproxy_install_renewal_hook
        return 0
    fi

    log_warning "真证书签发失败，降级为自签名证书。"
    log_warning "这不是「配好了」：客户端必须能勾「跳过证书校验」才连得上，很多客户端不行。"
    confirm "接受自签名证书？（选 n 就停下来先修 DNS/80 端口/防火墙）" \
        || die "已停止。修好之后重跑这条命令即可，已写入的东西是幂等的。"
    httpsproxy_selfsigned_cert "$domain"
}

httpsproxy_issue_letsencrypt() {
    local domain="$1" webroot="/var/www/html" probe probe_file
    local -a acct=()

    if ! command -v certbot >/dev/null 2>&1; then
        log_step "安装 certbot"
        # 绝不装 python3-certbot-nginx：那个插件会去改 Nginx 配置，和模板打架，
        # 还会让 hao-state.sh drift 天天报警。certonly 只负责签发。
        DEBIAN_FRONTEND=noninteractive apt-get update -y -qq \
            && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq certbot \
            || { log_error "certbot 安装失败"; return 1; }
    fi

    # 账户邮箱只在用户用 --email 给了的时候才带上。
    # 以前这里从域名拼一个 admin@<主域名>，有两个具体的坏处：
    #   1. `awk -F. '{print $(NF-1)"."$NF}'` 遇到多级后缀会算错 —— 形如
    #      a.example.co.uk 的域名会得到 co.uk，那是注册局的域名，
    #      等于把别人的地址填成账户联系人；
    #   2. 就算算对了，那个信箱多半根本不存在，吊销通知发进黑洞。
    # 没有邮箱是可以的（续期不需要它），明确地不注册比编一个好。
    if [ -n "${PROXY_EMAIL:-}" ]; then
        acct=(-m "$PROXY_EMAIL")
    else
        acct=(--register-unsafely-without-email)
        log_info "没给 --email，按「不注册联系邮箱」签发：续期照常，但出问题时 Let's Encrypt 联系不到你。"
    fi

    if [ "$(guard port-free 80)" = "free" ]; then
        log_step "签发证书（certbot --standalone，临时占用 80 端口）"
        certbot certonly --standalone -d "$domain" \
            --non-interactive --agree-tos "${acct[@]}" || return 1
        return 0
    fi

    # 80 被占：只有确认 challenge 路径真的能从公网取到，才值得去请求 LE ——
    # 失败的验证是要算进速率限制的。
    log_info "80 端口被占用（大概是 Nginx），改用 webroot 方式"
    if ! systemctl is-active --quiet nginx 2>/dev/null; then
        log_error "80 端口被占用，但占用者不是 Nginx，无法用 webroot 验证。"
        log_error "要么先腾出 80 端口，要么自己给那个服务加上 /.well-known/acme-challenge/ 的映射。"
        return 1
    fi

    install -d -m 0755 "$webroot/.well-known/acme-challenge"
    probe="hao-probe-$(openssl rand -hex 6)"
    probe_file="$webroot/.well-known/acme-challenge/$probe"
    printf '%s\n' "$probe" > "$probe_file"
    chmod 644 "$probe_file"

    # -L -k 是刻意的：Let's Encrypt 做 http-01 验证时会跟随重定向，并且不校验
    # 重定向到 https 之后的证书。探测要模仿它的行为，否则一个 80->443 跳转就会
    # 让我们误判成「路径不可达」而白白放弃一次本来能成功的签发。
    if [ "$(curl -sSLk --max-time 10 "http://$domain/.well-known/acme-challenge/$probe" 2>/dev/null)" = "$probe" ]; then
        log_success "challenge 路径可从公网取到（$webroot）"
        rm -f "$probe_file"
    else
        rm -f "$probe_file"
        log_error "取不到 http://$domain/.well-known/acme-challenge/ 下的文件。"
        log_error "Nginx 需要把这个路径映射到 $webroot。装了 HAO 的 nginx 模块就有现成的片段："
        log_error "  /etc/nginx/snippets/acme-challenge.conf（root 必须是 $webroot）"
        return 1
    fi

    log_step "签发证书（certbot --webroot）"
    certbot certonly --webroot -w "$webroot" -d "$domain" \
        --non-interactive --agree-tos "${acct[@]}" || return 1
}

# 自签名证书放 Debian 标准位置，**不塞进 /etc/letsencrypt/** ——
# 那个目录归 certbot 管，混进手工文件会让它和续期逻辑都变得难以理解。
httpsproxy_selfsigned_cert() {
    local domain="$1"
    install -d -m 0755 /etc/ssl/certs
    install -d -m 0700 /etc/ssl/private
    CERT_FULLCHAIN="/etc/ssl/certs/$domain.pem"
    CERT_KEY="/etc/ssl/private/$domain.key"

    if [ -f "$CERT_FULLCHAIN" ] && [ -f "$CERT_KEY" ] \
        && openssl x509 -in "$CERT_FULLCHAIN" -noout -checkend 604800 >/dev/null 2>&1; then
        log_info "复用现有自签名证书 $CERT_FULLCHAIN"
    else
        log_step "生成自签名证书（10 年）"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$CERT_KEY" -out "$CERT_FULLCHAIN" \
            -subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1 \
            || die "自签名证书生成失败"
        chmod 600 "$CERT_KEY"
        chmod 644 "$CERT_FULLCHAIN"
    fi
    CERT_KIND="自签名（客户端需勾「跳过证书校验」）"
    CERT_STATE="selfsigned"
}

httpsproxy_install_renewal_hook() {
    install -d -m 0755 "$(dirname "$RENEWAL_HOOK")"
    case "$(guard managed-file "$RENEWAL_HOOK")" in
        missing|"managed "*)
            install_template "certbot-deploy-hook-xray.sh.tmpl" "$RENEWAL_HOOK" 0755
            ;;
        *)
            log_warning "$RENEWAL_HOOK 已存在且不是本工具写的，不覆盖。续期后可能需要你手工重启 xray。"
            ;;
    esac
}

# ==================== 凭据 ====================
httpsproxy_ensure_credentials() {
    local credfile current_user
    local -a specs=() rotate=()
    credfile="$(cred_file "$HTTPSPROXY_SERVICE")"

    # 用户名不是密钥（它会出现在客户端配置里），但 hao-secret.sh 拒收命令行字面量，
    # 所以走 @env: 交进去。顺带避免它出现在 ps 输出里。
    export XP_PROXY_USER="$PROXY_USER"
    specs+=("PROXY_USER=@env:XP_PROXY_USER")

    # 用户名变了必须显式轮换：hao-secret.sh 默认复用已有值（那是「重跑不换线上口令」
    # 的保证），不轮换就会出现「命令行写了新用户名，实际生效的还是旧的」。
    if [ -f "$credfile" ]; then
        current_user="$(sed -n 's/^PROXY_USER=//p' "$credfile" | head -1)"
        if [ -n "$current_user" ] && [ "$current_user" != "$PROXY_USER" ]; then
            log_info "用户名从既有值改成 $PROXY_USER"
            rotate+=("PROXY_USER")
        fi
    fi

    case "$PASSWORD_SOURCE" in
        generate)
            specs+=("PROXY_PASSWORD=@password:32")
            ;;
        file)
            [ -r "$PASSWORD_ARG" ] || die "读不到口令文件: $PASSWORD_ARG"
            specs+=("PROXY_PASSWORD=@file:$PASSWORD_ARG")
            rotate+=("PROXY_PASSWORD")   # 用户明确给了口令，必须生效而不是被复用
            ;;
        env)
            [ -n "${!PASSWORD_ARG:-}" ] || die "环境变量 $PASSWORD_ARG 没设置或为空"
            specs+=("PROXY_PASSWORD=@env:$PASSWORD_ARG")
            rotate+=("PROXY_PASSWORD")
            ;;
    esac
    # 只往 rotate 里加，不再追加第二个 PROXY_PASSWORD spec ——
    # 同一个 key 出现两次会让凭据文件里出现两行同名 key，之后读到哪个都说不准。
    if [ "$ROTATE_PASSWORD" = true ]; then
        rotate+=("PROXY_PASSWORD")
    fi

    if [ "${#rotate[@]}" -gt 0 ]; then
        local joined
        joined="$(IFS=,; printf '%s' "${rotate[*]}")"
        secret write "$credfile" "${specs[@]}" --rotate "$joined"
    else
        secret write "$credfile" "${specs[@]}"
    fi
    unset XP_PROXY_USER
}

# ==================== 配置与客户端信息 ====================
httpsproxy_write_fragment() {
    local target="$XRAY_CONF_DIR/$HTTPSPROXY_FRAGMENT_NAME"
    local credfile tmpdir staged
    credfile="$(cred_file "$HTTPSPROXY_SERVICE")"

    case "$(guard managed-file "$target")" in
        missing|"managed "*) ;;
        *) die "$target 存在但不是本工具写的，不覆盖。" ;;
    esac

    tmpdir="$(make_tmpdir)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN
    staged="$tmpdir/fragment.json"

    render_plain "20-httpsproxy.json.tmpl" "$staged" 0600 \
        "PORT=$PROXY_PORT" \
        "DOMAIN=$PROXY_DOMAIN" \
        "CERT_FULLCHAIN=$CERT_FULLCHAIN" \
        "CERT_KEY=$CERT_KEY"

    secret render "$staged" "$target" --from "$credfile" --mode 0600
    assert_no_tokens "$target"
    log_success "已写入 $target (0600)——含口令，不要 cat 它"
}

httpsproxy_write_client_info() {
    local outfile credfile tmpdir staged
    outfile="$(client_file "$HTTPSPROXY_SERVICE")"
    credfile="$(cred_file "$HTTPSPROXY_SERVICE")"

    tmpdir="$(make_tmpdir)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN
    staged="$tmpdir/client.txt"

    render_plain "httpsproxy-client.txt.tmpl" "$staged" 0600 \
        "DOMAIN=$PROXY_DOMAIN" \
        "PORT=$PROXY_PORT" \
        "NODE_NAME=proxy-$PROXY_PORT" \
        "CERT_KIND=$CERT_KIND" \
        "GENERATED_AT=$(date -u '+%Y-%m-%d %H:%M:%SZ')"

    secret render "$staged" "$outfile" --from "$credfile" --mode 0600
    assert_no_tokens "$outfile"
    log_success "客户端参数已写入 $outfile (0600)"
}

# ==================== 端到端验证 ====================
# 真正走一遍代理。口令通过 curl 的配置文件交进去（0600 临时文件），
# 不进命令行参数、不进环境变量、不打印。
httpsproxy_verify_end_to_end() {
    local credfile tmpdir staged conf out rc=0
    local -a extra=()
    credfile="$(cred_file "$HTTPSPROXY_SERVICE")"

    if ! command -v curl >/dev/null 2>&1; then
        log_warning "没有 curl，跳过端到端验证"
        return 0
    fi

    # 自签名证书下加 --proxy-insecure：这一步要验的是「代理和认证通不通」，
    # 不是「证书可不可信」——后者已经在证书那一节如实说过了。
    # 判 CERT_STATE 而不是去匹配 CERT_KIND 的中文前缀：后者是给人看的文案，
    # 改一个字这里就静默失效。
    [ "$CERT_STATE" = "selfsigned" ] && extra+=(--proxy-insecure)

    tmpdir="$(make_tmpdir)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN
    staged="$tmpdir/curl.tmpl"
    conf="$tmpdir/curl.conf"

    render_plain "curl-proxy-check.conf.tmpl" "$staged" 0600 \
        "DOMAIN=$PROXY_DOMAIN" \
        "PORT=$PROXY_PORT"
    secret render "$staged" "$conf" --from "$credfile" --mode 0600 >/dev/null

    log_step "端到端验证：真的走一遍代理"
    # 先打到本机回环（--resolve 保留域名，所以证书和 SNI 照样被校验）。
    # 这样云安全组还没放行端口时也能验证「代理本身是通的」，不会误报成失败。
    out="$(curl -K "$conf" "${extra[@]+"${extra[@]}"}" \
        --resolve "$PROXY_DOMAIN:$PROXY_PORT:127.0.0.1" \
        https://api.ipify.org 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        rc=0
        log_info "回环路径没通，改从公网地址再试一次"
        out="$(curl -K "$conf" "${extra[@]+"${extra[@]}"}" https://api.ipify.org 2>&1)" || rc=$?
    fi

    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qE '^[0-9a-fA-F:.]+$'; then
        log_success "代理可用，出口 IP: $out"
        return 0
    fi

    case "$out" in
        *407*)
            log_error "代理返回 407（认证失败）：$out"
            die "账号没生效。检查 $XRAY_CONF_DIR/$HTTPSPROXY_FRAGMENT_NAME 里是不是 accounts 字段（不是 users）。"
            ;;
        *)
            log_warning "端到端验证没通过：$out"
            log_warning "配置测试和端口监听都是正常的，最常见的剩余原因是云安全组没放行 ${PROXY_PORT}/TCP，"
            log_warning "或本机 curl 版本太老（需要 7.52+ 才支持到代理走 TLS）。请从你自己的机器上再试一次。"
            ;;
    esac
}

# ==================== 主流程 ====================
cmd_proxy() {
    local want_selfsigned=false
    local ROTATE_PASSWORD=false
    local PASSWORD_SOURCE="generate" PASSWORD_ARG=""
    PROXY_DOMAIN=""
    PROXY_PORT="$HTTPSPROXY_PORT_DEFAULT"
    PROXY_USER="$HTTPSPROXY_USER_DEFAULT"
    PROXY_EMAIL=""
    CERT_KIND=""
    CERT_STATE=""
    CERT_FULLCHAIN=""
    CERT_KEY=""

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --domain) [ -n "${2:-}" ] || die "--domain 需要一个域名"; PROXY_DOMAIN="$2"; shift 2 ;;
            --port)   [ -n "${2:-}" ] || die "--port 需要一个端口号"; PROXY_PORT="$2";   shift 2 ;;
            --user)   [ -n "${2:-}" ] || die "--user 需要一个用户名"; PROXY_USER="$2";   shift 2 ;;
            --email)  [ -n "${2:-}" ] || die "--email 需要一个邮箱地址"; PROXY_EMAIL="$2"; shift 2 ;;
            --password-file)
                [ -n "${2:-}" ] || die "--password-file 需要一个路径"
                PASSWORD_SOURCE="file"; PASSWORD_ARG="$2"; shift 2 ;;
            --password-env)
                [ -n "${2:-}" ] || die "--password-env 需要一个变量名"
                PASSWORD_SOURCE="env"; PASSWORD_ARG="$2"; shift 2 ;;
            --rotate-password) ROTATE_PASSWORD=true; shift ;;
            --selfsigned) want_selfsigned=true; shift ;;
            -h|--help) httpsproxy_usage; return 0 ;;
            --password|--password=*)
                die "不接受用命令行参数传口令：同机任何用户都能从 /proc/<pid>/cmdline 读到。改用 --password-file 或 --password-env。" ;;
            *) httpsproxy_usage; die "未知参数: $1" ;;
        esac
    done

    [ -n "$PROXY_DOMAIN" ] || { httpsproxy_usage; die "必须给 --domain：证书和客户端都要用它。"; }
    if [ "$ROTATE_PASSWORD" = true ] && [ "$PASSWORD_SOURCE" != "generate" ]; then
        die "--rotate-password 和 --password-file/--password-env 只能给一个：前者是「随机换一个」，后者是「用我给的这个」。"
    fi
    validate_domain "$PROXY_DOMAIN"
    validate_port "$PROXY_PORT"
    validate_proxy_user "$PROXY_USER"

    require_root
    require_skill_scripts
    require_os
    require_cmds curl openssl systemctl ss

    # ---- 只读检查 ----
    log_step "只读检查"
    require_port_for_xray "$PROXY_PORT" "HTTPS 代理入站"
    httpsproxy_check_dns "$PROXY_DOMAIN"

    # ---- 讲清楚再动手 ----
    log_step "即将做的事"
    cat >&2 <<EOF
  1. 安装 xray-core 到 $XRAY_BIN，写 systemd 单元 $XRAY_UNIT（还没有的话）
  2. 给 $PROXY_DOMAIN 准备证书$([ "$want_selfsigned" = true ] && echo "（自签名）" || echo "（certbot 签 Let's Encrypt，装 certbot 包）")
  3. 生成或复用账号 $(cred_file "$HTTPSPROXY_SERVICE")（0600，口令值不显示）
  4. 写入站配置 $XRAY_CONF_DIR/$HTTPSPROXY_FRAGMENT_NAME（0600，含口令）
  5. 启用并启动 xray，监听 ${PROXY_PORT}/TCP
  6. 记录状态到 /var/lib/hao，服务名 $HTTPSPROXY_SERVICE

  不会动：现有的 Nginx 站点、80/443 端口、其他入站配置、防火墙规则。
EOF
    confirm "继续？" || die "已取消，什么都没改。"

    # ---- 执行 ----
    ensure_xray_core
    log_step "准备证书"
    httpsproxy_ensure_cert "$PROXY_DOMAIN" "$want_selfsigned"
    log_step "配置 HTTPS 代理入站"
    httpsproxy_ensure_credentials
    httpsproxy_write_fragment
    xray_apply "$PROXY_PORT" \
        || die "配置已写入，但服务没能正常起来——如实汇报，不要当成成功。"
    httpsproxy_write_client_info
    httpsproxy_verify_end_to_end

    # ---- 记录状态 ----
    log_step "记录状态"
    local -a resources=(
        "managed:$XRAY_CONF_DIR/$HTTPSPROXY_FRAGMENT_NAME"
        "secret:$(cred_file "$HTTPSPROXY_SERVICE")"
        "secret:$(client_file "$HTTPSPROXY_SERVICE")"
        "observed:$CERT_FULLCHAIN"
    )
    [ -f "$RENEWAL_HOOK" ] && resources+=("managed:$RENEWAL_HOOK")
    state record "$HTTPSPROXY_SERVICE" installed "${resources[@]}"
    state intent "$HTTPSPROXY_SERVICE" \
        protocol=https-proxy \
        domain="$PROXY_DOMAIN" \
        port="$PROXY_PORT" \
        proxy_user="$PROXY_USER" \
        cert="$CERT_STATE"
    state handoff

    notice_firewall "$PROXY_PORT"

    log_success "HTTPS 代理部署完成"
    cat >&2 <<EOF

  客户端里这样填：  https  $PROXY_DOMAIN  $PROXY_PORT  $PROXY_USER  <口令>
  口令和完整参数在：$(client_file "$HTTPSPROXY_SERVICE")   ← 0600，自己 sudo cat 去看

  证书：$CERT_KIND
  注意：这条代理只转 TCP（UDP / QUIC 走不了）；git、pip、apt、系统代理设置
        不支持「到代理走 TLS」，那些场景用 Clash 在本地转成明文 http 代理。
  再把 /var/lib/hao/DEPLOY-INTENT.md 存一份到自己的笔记里——机器销毁后那是重建依据。
EOF
}
