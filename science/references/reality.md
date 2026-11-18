# reality —— `VLESS + XTLS-Vision + REALITY` 抗封锁入站

不需要购买域名、不需要签发证书。REALITY 直接借用真实大厂站点（默认 `www.microsoft.com`）的 TLS 1.3 握手特征做伪装；遇到主动探测时把握手原样转发给目标真站，探测方拿到的是真站的合法证书，隐蔽性极强，且支持完整 TCP + UDP 转发。

适合手机端（Shadowrocket / v2rayNG / sing-box / Stash）与桌面客户端（v2rayN / Clash Verge Rev / Mihomo）作为主力连接。

前置条件：先完成 [core.md](core.md) 底座安装。

---

## 1. 只读检查

```bash
REALITY_PORT=8443                  # 若本机不跑网站也不在 443 跑 httpsproxy，也可直接用 443
DEST_SNI="www.microsoft.com"       # 伪装目标域名

# 1. 检查端口是否空闲
ss -tlnp | awk -v p=":${REALITY_PORT}" '$4 ~ p"$" {print}'

# 2. 检查伪装站点从本机是否真实可达且支持 TLS 1.3（连不上的伪装目标等于没有伪装！）
echo | openssl s_client -tls1_3 -connect "${DEST_SNI}:443" -servername "$DEST_SNI" 2>/dev/null \
    | openssl x509 -noout -subject -issuer
```

停止条件：
- `REALITY_PORT` 已被占用 → 换一个空闲端口，切勿强行覆盖。
- `openssl` 拿不到 `DEST_SNI` 的 TLS 1.3 证书 → 换一个从这台 VPS 真实可达的大站域名（如 `www.bing.com`、`www.apple.com`）。

---

## 2. 生成密钥并写入 `10-reality.json`

对应模板：`templates/10-reality.json.tmpl`。先在同一个 root Bash 会话定义 [暂存函数](core.md#修改配置时先暂存再应用)。此块用于新装或明确需要轮换密钥时。重用已有凭据请按 [迁移章节](migration.md) 填模板。
**安全约定：** 密钥在 `0700` 临时目录内生成并写入 `0600` 文件；若由 AI Agent 代为执行，**只汇报 `/etc/sing-box/clients/reality.txt` 路径，不把私钥和分享链接打印到聊天框**。

```bash
(
set -euo pipefail
prepare_sing_box
REALITY_PORT=8443
DEST_SNI="www.microsoft.com"
SERVER_IP="$(curl -fsS --max-time 8 https://api.ipify.org || hostname -I | awk '{print $1}')"

/usr/local/bin/sing-box generate reality-keypair > "$STAGE/keys"
PRIVATE_KEY="$(awk '/^PrivateKey:/ {print $2}' "$STAGE/keys")"
PUBLIC_KEY="$(awk '/^PublicKey:/ {print $2}' "$STAGE/keys")"
UUID="$(/usr/local/bin/sing-box generate uuid)"
SHORT_ID="$(/usr/local/bin/sing-box generate rand --hex 8)"
test -n "$PRIVATE_KEY" && test -n "$PUBLIC_KEY" && test -n "$SERVER_IP" || exit 1

cat << EOF > "$STAGE/conf.d/10-reality.json"
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${DEST_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${DEST_SNI}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ]
}
EOF

cat << EOF > "$STAGE/clients/reality.txt"
================================================================
  VLESS + Vision + REALITY 客户端参数（0600，请勿外传）
================================================================
[逐项填写]
  协议 (Protocol):  VLESS
  地址 (Server):    ${SERVER_IP}
  端口 (Port):      ${REALITY_PORT}
  UUID:             ${UUID}
  流控 (Flow):      xtls-rprx-vision
  传输 (Network):   tcp
  安全 (Security):  reality
  SNI (伪装域名):   ${DEST_SNI}
  公钥 (PublicKey): ${PUBLIC_KEY}
  ShortId:          ${SHORT_ID}
  指纹 (uTLS FP):   chrome

[一键导入分享链接]
vless://${UUID}@${SERVER_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#reality-${REALITY_PORT}

[Clash / Mihomo 节点片段]
  - name: "reality-${REALITY_PORT}"
    type: vless
    server: ${SERVER_IP}
    port: ${REALITY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${DEST_SNI}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome
================================================================
EOF
chmod 0600 "$STAGE/conf.d/10-reality.json" "$STAGE/clients/reality.txt"
apply_sing_box
)
```

自己在 SSH 终端查看生成的分享链接与节点配置：
```bash
sudo cat /etc/sing-box/clients/reality.txt
```

---

## 3. 真证据验收

```bash
REALITY_PORT=8443
DEST_SNI="www.microsoft.com"

# 1. 确认端口已在监听
ss -tlnp | grep ":${REALITY_PORT}"

# 2. 模拟无密钥主动探测：必须拿到伪装目标站点的真实官方证书（证明伪装回落生效！）
echo | openssl s_client -connect "127.0.0.1:${REALITY_PORT}" -servername "$DEST_SNI" 2>/dev/null \
    | openssl x509 -noout -subject -issuer
```

随后放行系统防火墙及云厂商后台安全组的 `${REALITY_PORT}/TCP` 入站规则，用手机或电脑客户端扫码/导入链接实测连通即可。

---

## 4. 常见现象排错与单独卸载

- **日志里出现 `REALITY: processed invalid connection`**：
  - **绝大多数情况是正常的**：全网扫描器（或上面的 `openssl` 验收命令）不带密钥探测端口时，被 REALITY 识别并透明回落给了伪装站点，说明主动防御正在工作。
  - **如果真实客户端连不上且同步刷这条日志**：核对客户端是否漏开了 **`flow: xtls-rprx-vision`**，以及 `UUID`、`PublicKey`、`ShortId`、`SNI` 四项是否与 `reality.txt` 完全一致。
- **单独停用/卸载**：
  ```bash
  (
  set -euo pipefail
  prepare_sing_box
  rm -f "$STAGE/conf.d/10-reality.json" "$STAGE/clients/reality.txt"
  apply_sing_box
  )
  ```
