# httpsproxy —— 浏览器免客户端 `HTTP/2` 正向代理（TLS + 账号口令）

适合不想在电脑上安装常驻翻墙客户端、直接用 Chrome 扩展 **ZeroOmega（SwitchyOmega 维护版）** 直连海外 VPS 的场景，也兼容 Shadowrocket / Clash / Mihomo / Surge / `curl` 等支持 `HTTPS` 代理的工具。

## 核心原理与使用边界（先讲清楚）

1. **为什么必须用 `HTTP/2` (`h2`)？**
   现代网页打开一次普遍要并发加载 15～30 个不同子域名。旧式 `HTTP/1.1` 代理每连一个新域名都要跨太平洋重握一次 TCP+TLS，并发爆发十几条 TLS 握手时极易被跨国链路丢包掐断，导致网页白屏转圈几十秒。开启 `HTTP/2` 后，Chrome 与 VPS 只维持 **1 条长连接**，所有子域名请求在单条加密隧道内多路复用，新建隧道只需 1 个物理 RTT。
2. **硬性边界：**
   - **只转 TCP，不转 UDP**（网页浏览、看视频完全够用；UDP 游戏或原生 QUIC 会自动回落到 TCP，需要全流量 UDP 请用 [reality.md](reality.md)）。
   - **必须有域名和受信任证书**：Chrome 对 `HTTPS` 代理强制校验证书合法性，不支持直接填 IP 或自签名证书。
   - **不支持明文代理栏**：`git`、`pip`、`apt` 及 Windows/macOS 系统设置里的“HTTP 代理”只认明文代理，不能直接填本代理地址。

前置条件：先完成 [core.md](core.md) 底座安装，并准备好一个已将 `A` 记录解析到本机公网 IP 的域名（若用 Cloudflare，**必须关掉橙云设为灰云 DNS only**）。

---

## 1. 只读检查

设定你的目标域名与端口（新机器若 `443` 空闲**首选 `443`**；若 `443` 已被 Nginx 建站占用，推荐 `8443`、`2053` 或 `8445`）：

```bash
PROXY_DOMAIN="proxy.example.com"   # 换成你的真实域名
PROXY_PORT=443                     # 换成你的目标端口

# 1. 检查目标端口是否空闲
ss -tlnp | awk -v p=":${PROXY_PORT}" '$4 ~ p"$" {print}'

# 2. 检查域名 A 记录是否已指向本机公网 IP
SERVER_IP="$(curl -fsS --max-time 8 https://api.ipify.org)"
RESOLVED_IPS="$(getent ahostsv4 "$PROXY_DOMAIN" | awk '{print $1}' | sort -u | tr '\n' ' ')"
echo "本机公网 IP: ${SERVER_IP} | 域名解析结果: ${RESOLVED_IPS:-无}"

# 3. 检查是否已有现成的 Let's Encrypt 证书，以及 80 端口占用情况（决定签发方式）
ls -l "/etc/letsencrypt/live/${PROXY_DOMAIN}/fullchain.pem" 2>/dev/null || echo "尚无证书"
ss -tlnp | awk '$4 ~ /:80$/ {print}'
```

停止条件：
- `PROXY_PORT` 已被其他非 `sing-box` 程序占用 → 换端口（如 `8443` / `2053`），不要强抢。
- `RESOLVED_IPS` 不包含 `SERVER_IP` → 停下，先去修 DNS 解析或关掉 Cloudflare 橙云，避免白白消耗 Let's Encrypt 失败速率限制。

---

## 2. 签发 TLS 证书（Certbot）

**铁律：只装 `certbot` 主包，绝不装 `python3-certbot-nginx` 插件**（该插件会自动篡改 Nginx 配置文件）。

```bash
command -v certbot >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get install -y -qq certbot
}

# 分支 A：若 80 端口空闲，直接用 --standalone 临时占 80 签发（云安全组需放行 80/TCP）
certbot certonly --standalone -d "$PROXY_DOMAIN" \
    --non-interactive --agree-tos --register-unsafely-without-email

# 分支 B：若 80 端口已被本机 Nginx 占用，改用 --webroot（假设验证目录为 /var/www/html）
# certbot certonly --webroot -w /var/www/html -d "$PROXY_DOMAIN" \
#     --non-interactive --agree-tos --register-unsafely-without-email
```

从仓库根目录安装证书自动续期重载钩子。迁移时若复用现有证书，沿用它的签发和续期设置，只安装此钩子。

```bash
bash -n science/templates/certbot-deploy-hook-sing-box.sh.tmpl &&
    install -D -m 0755 science/templates/certbot-deploy-hook-sing-box.sh.tmpl \
        /etc/letsencrypt/renewal-hooks/deploy/reload-sing-box.sh
```

---

## 3. 生成随机凭据并写入 `20-httpsproxy.json`

对应模板：`templates/20-httpsproxy.json.tmpl`。先在同一个 root Bash 会话定义 [暂存函数](core.md#修改配置时先暂存再应用)。
**安全约定：** 账号与口令在本地内存中直接随机生成并写入 `0600` 文件，不通过命令行参数传递（防 `/proc/<pid>/cmdline` 泄露）；如果是 AI Agent 代为执行，**只告知用户客户端参数文件路径，不要把口令打印到聊天记录里**。

```bash
(
set -euo pipefail
prepare_sing_box
PROXY_DOMAIN="proxy.example.com"   # 保持与上面一致
PROXY_PORT=443

# 避免使用 admin / user 等常见扫描字典弱用户名
PROXY_USER="px_$(openssl rand -hex 3)"
PROXY_PASS="$(openssl rand -hex 24)"

cat << EOF > "$STAGE/conf.d/20-httpsproxy.json"
{
  "inbounds": [
    {
      "type": "http",
      "tag": "httpsproxy-in",
      "listen": "::",
      "listen_port": ${PROXY_PORT},
      "version": [1, 2],
      "users": [
        {
          "username": "${PROXY_USER}",
          "password": "${PROXY_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${PROXY_DOMAIN}",
        "alpn": [
          "h2",
          "http/1.1"
        ],
        "certificate_path": "/etc/letsencrypt/live/${PROXY_DOMAIN}/fullchain.pem",
        "key_path": "/etc/letsencrypt/live/${PROXY_DOMAIN}/privkey.pem"
      }
    }
  ]
}
EOF

cat << EOF > "$STAGE/clients/httpsproxy.txt"
================================================================
  sing-box HTTP/2 正向代理客户端参数（0600，请勿外传）
================================================================
[一行速查]
https ${PROXY_DOMAIN} ${PROXY_PORT} ${PROXY_USER} ${PROXY_PASS}

[Chrome ZeroOmega / SwitchyOmega 填写方式]
  代理协议:   HTTPS
  代理服务器: ${PROXY_DOMAIN}
  代理端口:   ${PROXY_PORT}
  用户名:     ${PROXY_USER}
  密码:       ${PROXY_PASS}

[Clash / Mihomo 节点片段]
  - name: "h2-proxy-${PROXY_PORT}"
    type: http
    server: ${PROXY_DOMAIN}
    port: ${PROXY_PORT}
    username: ${PROXY_USER}
    password: ${PROXY_PASS}
    tls: true
    sni: ${PROXY_DOMAIN}
================================================================
EOF
chmod 0600 "$STAGE/conf.d/20-httpsproxy.json" "$STAGE/clients/httpsproxy.txt"
apply_sing_box
)
```

查看生成的连接参数（自己在 SSH 终端里运行）：
```bash
sudo cat /etc/sing-box/clients/httpsproxy.txt
```

---

## 4. 验收 HTTP/2 代理和目标请求

在服务器上使用支持 HTTP/2 的 curl 8.1.0 或更新版本。下面检查代理协商的协议、CONNECT 状态和目标 HTTP 状态。curl 诊断可能包含认证头，和凭据配置一同保存到权限受限的临时目录，运行结束后自动清理。

```bash
(
set -euo pipefail
umask 077
TMP_CURL="$(mktemp -d)"
trap 'rm -rf -- "$TMP_CURL"' EXIT
IFS= read -r entry < <(grep -m 1 '^https ' /etc/sing-box/clients/httpsproxy.txt)
format='^https ([A-Za-z0-9.-]+) ([0-9]{1,5}) ([^[:space:]:]+) (.+)$'
if [[ ! "$entry" =~ $format ]]; then
    printf '客户端说明中的 HTTPS 速查行格式有误\n' >&2
    exit 1
fi
domain="${BASH_REMATCH[1]}"
port="${BASH_REMATCH[2]}"
# curl 配置的双引号值需要转义反斜杠与双引号。
credentials="${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
credentials="${credentials//\\/\\\\}"
credentials="${credentials//\"/\\\"}"
printf 'proxy = "https://%s:%s"\nproxy-user = "%s"\n' "$domain" "$port" "$credentials" > "$TMP_CURL/config"

for host in www.google.com www.gstatic.com; do
    if ! status="$(curl -q --silent --show-error --verbose --max-time 20 --noproxy '' \
        --config "$TMP_CURL/config" --proxy-http2 --resolve "$domain:$port:127.0.0.1" \
        --output /dev/null --write-out '%{http_code}' \
        "https://$host/generate_204" 2>"$TMP_CURL/diagnostic")"; then
        printf '验收失败：%s，curl 传输失败，目标 HTTP %s\n' "$host" "$status" >&2
        exit 1
    fi
    if ! grep -Fxq '* CONNECT tunnel: HTTP/2 negotiated' "$TMP_CURL/diagnostic" ||
        ! grep -Fxq '* CONNECT tunnel established, response 200' "$TMP_CURL/diagnostic" ||
        [[ "$status" != 204 ]]; then
        printf '验收失败：%s，目标 HTTP %s，预期通过 HTTP/2 CONNECT 200 后返回 204\n' "$host" "$status" >&2
        exit 1
    fi
    printf '%s：HTTP/2 CONNECT 200，目标 HTTP 204\n' "$host"
done
)
```

两项通过后，从实际客户端复测。按选定端口核对系统防火墙和云安全组的 TCP 入站规则。

---

## 5. 客户端 ZeroOmega 避坑提醒

- 在 ZeroOmega 的**代理服务器**情景模式中，协议选 **`HTTPS`**，填入域名、端口和账号密码即可。
- **自动切换（Auto Switch）大坑**：如果配了自动分流规则，**只用域名通配符（Host Wildcard，如 `*.google.com`）**，切勿导入依赖 IP 段判断（触发 PAC `dnsResolve()`）的规则——否则每次打开网页 Chrome 都会先在国内本地网络去解析被墙域名，白白卡顿超时 1～3 秒。
- 可用 Node.js 18+ 在客户端跑 10 域名并发验证。先把客户端说明安全地传到本机私有目录，限制为本机账户可读（Linux/macOS 用 `chmod 600`，Windows 使用文件 ACL），再运行 `node science/scripts/bench-h2.mjs --credentials-file ./httpsproxy.txt`。

---

## 6. 换密码或单独卸载

- **换密码**：通过 [暂存流程](core.md#修改配置时先暂存再应用) 更新同一账户在配置与客户端说明里的密码。保留其他账号，再应用并验收。
- **单独停用/卸载**：
  ```bash
  (
  set -euo pipefail
  prepare_sing_box
  rm -f "$STAGE/conf.d/20-httpsproxy.json" "$STAGE/clients/httpsproxy.txt"
  apply_sing_box
  rm -f /etc/letsencrypt/renewal-hooks/deploy/reload-sing-box.sh
  )
  ```
