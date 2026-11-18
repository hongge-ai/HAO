# 从 Xray 迁移到 sing-box

适用于本仓库旧版 Xray 部署。自定义入站、出站、路由和服务单元需要逐项核对。使用一条独立的 SSH 管理连接执行切换。

## 1. 只读盘点与用户确认

```bash
systemctl show xray sing-box -p Id -p FragmentPath -p ExecStart -p ActiveState -p UnitFileState
ss -lntup
```

记录实际的 Xray 单元名、配置目录、使用中的入站端口、证书路径及续期方式。旧版默认配置目录为 `/usr/local/etc/xray/conf.d/`，凭据和客户端说明位于 `/etc/hao/`。仅在目标机本地查看必要字段，记录时省略凭据和完整分享链接。若已有 sing-box 在运行，先确认它是否承载其他业务。

如果代用户操作，先告知将停用的服务、受影响的端口和客户端、预计中断、凭据是否保留、验收方法和回滚方式。**等用户明确同意后，才在目标主机上备份、安装、写配置或切换服务。** 用户未确认时停在只读盘点。

## 2. 备份与准备候选配置

1. 把实际使用的 Xray 单元和 drop-in、配置目录、凭据、客户端说明和续期钩子复制到 root 专用的 `0700` 备份目录。记下 Xray 原先是否在运行、是否随系统启动。切换期间保留旧二进制、配置、钩子和实际证书文件。
2. 保持 Xray 运行，按 [底座章节](core.md) 安装 sing-box，服务留到切换时启动。在同一 root Bash 会话定义底座章节的暂存函数，并准备候选目录。

   ```bash
   CANDIDATE="$(mktemp -d)" &&
       install -d -m 0700 "$CANDIDATE/conf.d" "$CANDIDATE/clients" &&
       install -m 0644 /etc/sing-box/conf.d/00-base.json "$CANDIDATE/conf.d/00-base.json"
   ```

   把以下对应模板渲染到 `$CANDIDATE/conf.d/`，含凭据的配置设为 `0600`。把客户端说明写进 `$CANDIDATE/clients/`，权限同为 `0600`。若 HTTPS 代理复用旧凭据，按 HTTPS 章节的格式记录速查行，供验收使用。

   | 旧入站 | 新配置 | 沿用现有客户端时需保留的参数 |
   | --- | --- | --- |
   | VLESS / REALITY | `10-reality.json` | 地址、端口、UUID、flow、SNI、握手目标、服务端私钥与对应公钥、short ID。公钥留在客户端配置中 |
   | HTTPS 代理 | `20-httpsproxy.json` | 代理域名、地址、端口、用户名、密码和实际证书链及私钥路径。证书继续使用原来的续期 lineage |

   保留现有凭据时直接从备份核对并填写模板。新装章节的凭据生成命令会为客户端生成新参数。旧配置中有 JSON 特殊字符的字段，应使用 JSON 序列化写入。候选配置须覆盖仍在使用的每个入站，包含旧部署要求保留的监听地址和认证配置。
3. 先执行 `/usr/local/bin/sing-box check -D /var/lib/sing-box -C "$CANDIDATE/conf.d"`。若条件允许，用不同端口或独立测试机做客户端预验收。共用端口的正式切换继续使用已校验的候选配置。

## 3. 切换与验收

在已同意的窗口内，确认 Certbot 没有正在续期。若旧 Xray 续期钩子会重启服务，先把钩子移到备份目录，避免切换和验收期间拉起 Xray。保留原路径和权限记录，以便回滚。

从原 root Bash 会话执行下方命令，把 `XRAY_UNIT` 改为盘点时查到的单元名。下方流程适用于 sing-box 尚未承载业务的目标机。

```bash
(
set -euo pipefail
XRAY_UNIT=xray.service
prepare_sing_box
cp -a "$CANDIDATE/conf.d/." "$STAGE/conf.d/"
cp -a "$CANDIDATE/clients/." "$STAGE/clients/"
/usr/local/bin/sing-box check -D /var/lib/sing-box -C "$STAGE/conf.d"
systemctl is-active --quiet "$XRAY_UNIT"
systemctl stop "$XRAY_UNIT"
if ! apply_sing_box; then
    systemctl stop sing-box.service && systemctl start "$XRAY_UNIT"
    exit 1
fi
)
```

检查端口监听、服务日志、REALITY 客户端和 HTTPS 代理的实际请求。使用 Let's Encrypt 时，确认原证书可读取，并部署 [sing-box 的续期钩子](httpsproxy.md#2-签发-tls-证书certbot)。验收通过后，先启用 sing-box 开机启动，再禁用旧单元的开机启动。保留旧配置和钩子备份至回滚期结束，并清理本次候选目录中的凭据副本。

## 4. 回滚

启动或客户端验收失败时，先停止 sing-box，确认共用端口释放后启动原 Xray 单元。若已调整开机启动，恢复盘点时记录的设置。下面适用于原 Xray 已启用开机启动、新旧服务不能共用端口的部署。

```bash
(
set -euo pipefail
systemctl stop sing-box.service
systemctl start xray.service
systemctl disable sing-box.service
systemctl enable xray.service
systemctl is-active --quiet xray.service
)
```

从现有客户端再次验证原服务。若切换时改过客户端、续期钩子或防火墙，按备份与盘点记录恢复。
