# 出网工具书

本目录记录 sing-box 的手工部署、验证与回滚步骤，适用于使用 systemd 的 Debian/Ubuntu。配置和服务单元在 [templates/](templates/)，命令与操作说明在各章节。准备一条独立的 SSH 管理连接，再以 root 在目标服务器上执行各章命令。

## 从哪里开始

| 场景 | 阅读顺序 |
| --- | --- |
| 新机器 | 先装 [sing-box 底座](references/core.md)，再选择下方入站 |
| 已有 Xray | 先读 [迁移与回滚](references/migration.md)，盘点现有服务并确认切换窗口 |
| VLESS 客户端 | [REALITY 入站](references/reality.md) |
| 浏览器或工具直接使用 HTTPS 代理 | [HTTPS 代理入站](references/httpsproxy.md) |
| 已有入站，需要额外的出站节点 | [链式出站](references/landing.md) |
| 单独调整 Linux TCP 拥塞控制与队列 | [BBR 与 fq](references/bbr.md) |

## 配置与验收

配置目录是 `/etc/sing-box/conf.d/`，客户端连接说明保存在 `/etc/sing-box/clients/`。目录里的私钥、UUID 和口令仅供有权限的操作者使用。变更前按底座章节暂存并验证完整配置，启动后按对应章节从客户端验收，再启用开机启动。

状态查看使用 `systemctl status sing-box`，日志使用 `journalctl -u sing-box`。HTTPS 代理的可选并发检查见该章的客户端小节。
