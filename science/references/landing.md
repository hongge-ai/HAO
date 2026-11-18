# landing —— 进阶：链式落地分流（双 ISP / 原生住宅 IP 出站）

当你手里的主力 VPS **回国线路快，但机房 IP 被 ChatGPT / Claude / TikTok / 流媒体风控嫌弃**时，可以再买一台便宜的“双 ISP / 原生家宽 IP 落地机”（落地机按 [reality.md](reality.md) 装好 `VLESS + REALITY` 即可），然后在主力机上放入 `30-landing.json` 实现**链式代理分流**。

## 分流效果（单端口双账号切线路神技）

得益于 `sing-box` 按文件名字典序追加合并配置（`00-base` -> `10-reality` -> `20-httpsproxy` -> `30-landing`）：
1. **安全不降级**：`00-base.json` 的首条规则（拦截私有地址 `ip_is_private -> reject`）依然排在第 1 位最先执行；
2. **`reality-in` 全量走落地**：手机/客户端连 `8443` 的流量自动转发到纯净落地机出站；
3. **Chrome ZeroOmega 单端口双账号秒切线路**：
   - 在 `20-httpsproxy.json` 的 `users` 数组里配两个账号（例如默认账号 `px_direct` 和落地专属账号 `px_isp`）；
   - 在 ZeroOmega 里建两个情景模式（同一个域名和端口，只换用户名密码）：日常刷网页/看视频选 `px_direct` 走主力机直连吃满带宽，遇到高风控网站点一下扩展切到 `px_isp` 立即变成双 ISP 纯净住宅 IP！

---

## 1. 只读检查（先确认主力机到落地机可达）

```bash
LANDING_SERVER="203.0.113.10"      # 替换成落地机的公网 IP 或域名
LANDING_PORT=443                   # 替换成落地机的 REALITY 端口
LANDING_SNI="www.microsoft.com"    # 替换成落地机的 REALITY SNI

# 确认从主力机能连上落地机端口，并能正常看到落地机的 REALITY 伪装证书
echo | openssl s_client -connect "${LANDING_SERVER}:${LANDING_PORT}" -servername "$LANDING_SNI" 2>/dev/null \
    | openssl x509 -noout -subject -issuer
```

---

## 2. 部署步骤

先在同一个 root Bash 会话定义 [暂存函数](core.md#修改配置时先暂存再应用)。按 `templates/30-landing.json.tmpl` 和落地机的 `reality.txt` 填写配置。若已启用 HTTPS 代理且要新增 `px_isp` 账号，把 `ADD_ISP_USER` 设为 `1`。已有该账号时保留现有密码。

```bash
(
set -euo pipefail
prepare_sing_box
ADD_ISP_USER=0
if [[ "$ADD_ISP_USER" = 1 ]]; then
    python3 - "$STAGE" << 'PY'
import json
import re
import secrets
import sys
from pathlib import Path

stage = Path(sys.argv[1])
config_path = stage / "conf.d/20-httpsproxy.json"
client_path = stage / "clients/httpsproxy.txt"
config = json.loads(re.sub(r"^\s*//.*$", "", config_path.read_text(encoding="utf-8"), flags=re.M))
inbound = next(item for item in config["inbounds"] if item["tag"] == "httpsproxy-in")
users = inbound["users"]
if all(user["username"] != "px_isp" for user in users):
    password = secrets.token_hex(24)
    users.append({"username": "px_isp", "password": password})
    config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
    with client_path.open("a", encoding="utf-8") as client_file:
        client_file.write(f"\n[落地账号]\n  用户名: px_isp\n  密码:   {password}\n")
    client_path.chmod(0o600)
    config_path.chmod(0o600)
PY
fi

cat << 'EOF' > "$STAGE/conf.d/30-landing.json"
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "landing-out",
      "server": "替换成落地机IP",
      "server_port": 443,
      "uuid": "替换成落地机UUID",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "替换成落地机SNI",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "替换成落地机PublicKey",
          "short_id": "替换成落地机ShortID"
        }
      }
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": [
          "reality-in"
        ],
        "outbound": "landing-out"
      },
      {
        "inbound": [
          "httpsproxy-in"
        ],
        "auth_user": [
          "px_isp"
        ],
        "outbound": "landing-out"
      }
    ]
  }
}
EOF

chmod 0600 "$STAGE/conf.d/30-landing.json"
apply_sing_box
)
```

---

## 3. 真证据验收（确认两条出口 IP 分流精准）

在连接了对应节点的客户端或服务端用 `curl` 访问 `https://ipinfo.io/ip`：
- 走默认 `httpsproxy` 账号 → 返回**主力机自己的 IP**；
- 走 `px_isp` 账号或 `8443` `reality-in` → 返回**后端落地机的纯净 IP**！

---

## 4. 临时切回直连或卸载落地分流

通过同一暂存流程停用分流，其他入站继续使用当前配置。

```bash
(
set -euo pipefail
prepare_sing_box
test ! -e "$STAGE/conf.d/30-landing.json.disabled"
mv "$STAGE/conf.d/30-landing.json" "$STAGE/conf.d/30-landing.json.disabled"
apply_sing_box
)
```

彻底删除时，在暂存目录中删除相应文件，再调用 `apply_sing_box`。
