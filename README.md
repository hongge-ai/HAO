# HAO — HongAgentOps

> **一个 AI agent skill**，帮你把一台 Debian/Ubuntu 服务器变成能用的东西：
> 一个上线的网站，或者一台能干活、能学习的机器。
>
> 你不需要懂运维。说清你想要什么，agent 负责检查、部署、验证，
> 并在主机上留下交接记录——之后任何 agent 接手都照同一套规则走。

HAO（HongAgentOps）不是命令行工具，是一套**给 AI agent 用的部署知识**：
过程文档 + 配置模板 + 四个守住确定性的小脚本。

## 两种运行方式

| 方式 | 适用 | Claude Code 跑在哪 |
|---|---|---|
| **远程（推荐）** | 你坐在笔记本前，要操作一台或几台 VPS | 你的笔记本，通过 SSH 驱动服务器 |
| **本地** | 机器本身就是开发机，或你已经在服务器上 | 服务器 |

远程模式下服务器上什么都不用装——HAO 把几个脚本推到 `/tmp` 下临时执行，用完就删。
详情见 `skills/hao-deploy/references/remote.md`。

## 安装（远程模式）

**1. 在你的笔记本上装 Claude Code**（已有就跳过）。

Windows 11 自带 OpenSSH 客户端；其他系统装 `openssh-client`。还需要 Git Bash
（Windows）或普通的 bash。

```
/plugin marketplace add hongge-ai/HAO
/plugin install hao@hao
```

**2. 直接说你要连哪台机器**：

> 连一下 104.233.149.80，端口 46868，root

第一次连接 agent 会先把主机指纹念给你确认，然后引导你装一把专用公钥
（`~/.ssh/hao_ed25519`）。之后所有连接都走这把钥匙，不再用密码。

**3. 说你要什么**：

> 这台是刚买的，先弄安全一点

> 帮我把 github.com/me/blog 部署到 blog.example.com

> 这台机器上装了什么？

## 安装（本地模式）

机器本身就是目标服务器时，先装 Claude Code，再装 HAO。刚买的机器上完整是这两步：

**1. 装 Claude Code**（这一步没人能替你做，之后才有 `/plugin` 可用）：

```bash
ssh <你的用户>@<服务器IP>

# Node.js 18+。发行版自带的可能太旧，用 NodeSource 的 apt 源。
# 这里不用 `curl … | bash` 那种一键脚本：装完这一步之后，同样的事情由 HAO 的
# node 模块来做（keyring + apt 源，见 skills/hao-deploy/references/node.md），
# 两边保持一个做法。
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list
sudo apt-get update && sudo apt-get install -y nodejs

sudo npm install -g @anthropic-ai/claude-code
claude          # 首次运行会让你登录
```

**2. 装 HAO**（在 `claude` 里敲这两条）：

```
/plugin marketplace add hongge-ai/HAO
/plugin install hao@hao
```

之后要装别的（Node、Docker、uv…）都由 agent 来做。

## 远程模式的安全边界

- **主机密钥钉死。** 第一次连接必须人工确认指纹，写进 `~/.ssh/hao_known_hosts`；
  之后任何变更都是硬失败，不是「更新一下」。
- **密码只用一次。** 装公钥那一步要么你自己在终端跑 `ssh-copy-id`，要么让
  agent 读一个你自己建的 0600 文件；用完即删。密码永远不进命令行参数。
- **目标身份先确认再动手。** `probe` 会报 hostname、公网 IP、系统版本；
  没念给你确认之前不做任何写入。错机器上的 guard 检查全部返回放行值，
  这是唯一能拦住它的东西。
- **远端脚本过门禁才执行。** `bash -n`、无 CRLF、树哈希一致，三条全过才启用。

## 能装什么

| 模块 | 内容 |
|---|---|
| `fail2ban` | SSH 防爆破，自动探测机器真实的 SSH 端口 |
| `swap` | swap 文件 + 换出倾向调优，小内存机器防 OOM |
| `journald` | 系统日志占用上限，防止日志写爆根分区 |
| `nginx` | Nginx（nginx.org 源，含 HTTP/3）+ BBR 与内核调优 |
| `docker` | Docker Engine + Compose 插件 + 容器日志轮转 |
| `node` | 系统级 Node.js LTS（落在 `/usr/bin`，systemd 服务可用） |
| `uv` | uv Python 环境管理器 + 写入「一律用 uv」的 agent 约定 |
| `claude-code` | Claude Code CLI + 网关/模型配置 |
| `git` | Git + 提交身份（身份必须你自己给，不会替你猜） |
| `gh` | 官方 GitHub CLI + 独立的授权助手 |
| `site` | 从 Git 仓库部署静态站或 Node 站，含 Let's Encrypt 证书与更新脚本 |
| `nginx-hardening` | 站点防护基线：真实 IP 还原、扫站/恶意 UA 拦截、限流、安全响应头 |
| `fail2ban-nginx` | 站点扫站（403/404）与后台爆破的自动封禁 |

**一个工具一个模块。** 你说「服务器刚买的，先弄安全一点」，agent 会装
`fail2ban` + `swap` + `journald` 三件——但它们各自独立记录、独立检查漂移、
可以单独卸载，不会绑成一个拆不开的包。

支持系统：Debian 13/12，Ubuntu 26.04/24.04/22.04 LTS。
验收只在 Ubuntu 上做（见下）。

**部署结果用业内通用的路径和工具，没有 HAO 专属布局。** 源码在 `/opt/<站点ID>`，
静态产物在 `/var/www/<域名>`，vhost 在 `/etc/nginx/conf.d/<域名>.conf`，
systemd 单元叫 `<站点ID>.service`，证书由 **certbot** 签在
`/etc/letsencrypt/live/<域名>/` 并自动续期。一个没听说过 HAO 的运维人员登上机器，
在他习惯的位置就能找到东西 —— 如果 HAO 留下的东西只有 HAO 能维护，
那就是把你锁在了 HAO 上。

**不包含具体第三方应用的部署过程。** HAO 只装通用的运维底座，以及从你自己的
仓库部署站点。要装某个具体应用（模型网关、论坛、面板之类）时，HAO 帮你把
`docker` + `nginx` 底座和反代证书弄好，应用本身按上游官方文档装——那些应用各有
自己的初始化流程、默认口令和数据迁移语义，写成通用过程只会给出似是而非的步骤。

## 交接契约：机器可以扔，知识不能丢

服务器可以是即用即抛的，部署它的那次对话也一定会消失。所以 HAO 把状态写在
**主机上**，而不是留在聊天记录里：

```
/var/lib/hao/
├── HANDOFF.md          给下一个 agent 看：装了什么、凭据在哪、什么不能碰
├── DEPLOY-INTENT.md    给你带走：怎么在新机器上重放这次部署（不含密钥）
├── manifest.json       机器可读的资源清单（含归属类别与内容哈希）
└── services/           每个服务一份记录
```

凭据不在这里，在 `/etc/hao/<服务>.env`（文件 `0600`，目录 `0700`）。分开放是
因为**状态可再生、凭据不可再生**：`/var/lib` 按惯例是可丢弃的再生状态，备份策略
经常整体排除它，而凭据丢了服务就废了。

要注意 `/var/lib/hao` **是索引而不是容器**：vhost 在 `/etc/nginx`、systemd 单元在
`/etc/systemd/system`、apt 源在 `/etc/apt`——那些位置是消费它们的程序规定的，
挪不动。想知道 HAO 动过哪些文件，查 `manifest.json`。

部署收尾时 skill 会把一个指针块写进本机 AI 助手的指令文件，
所以**下一个 agent 不需要谁告知，开机就知道这台机器由 HAO 管理**。

资源分四种归属，决定后续 agent 能做什么：

| 归属 | 含义 | 允许的操作 |
|---|---|---|
| `managed` | HAO 创建并负责 | 可按流程重写；发现漂移要先问人 |
| `shared` | HAO 改过、但属于系统 | 只能改自己那部分，不可整体覆盖 |
| `observed` | 仅记录 | 只读 |
| `secret` | 凭据文件 | 只报路径，永不打印内容 |

随时可以查（skill 装在插件缓存里，路径带一段内容哈希，所以别手敲——
用 `/plugin` 看，或者直接问 agent "这台机器上装了什么"）：

```bash
SKILL="$(dirname "$(find ~/.claude/plugins/cache -name hao-state.sh | head -1)")"
"$SKILL/hao-state.sh" services      # 装了什么
"$SKILL/hao-state.sh" drift         # 有没有被手工改过
"$SKILL/hao-state.sh" credentials   # 凭据文件路径（不含内容）
```

**机器销毁前**：把 `/var/lib/hao/DEPLOY-INTENT.md` 存到你自己的笔记或仓库里。
它是这台机器上唯一值得带走的东西——有了它在新机器上重放一遍就行。凭据不在其中，
按设计不可重放；要留旧密码得自己从凭据文件导出。

## 安全底线

- **改系统之前先讲清楚并取得确认。** 只读检查不需要确认。
- **绝不覆盖不属于自己的东西。** 目标已存在且不是 HAO 管理的，一律停下来问。
- **凭据只报路径。** 密钥由 `hao-secret.sh` 生成并直接落到 0600 文件，
  值不经过对话；注入配置用模板渲染，不把密钥读出来再拼。
- **如实汇报。** 失败说失败，证书降级说降级，BBR 没生效说没生效。
- 不做卸载、删 volume、改 SSH/防火墙这类操作，除非用户明确要求那件具体的事。

完整版见 `skills/hao-deploy/references/safety.md`。

## 仓库结构

```
skills/hao-deploy/
├── SKILL.md            入口：工作流程与硬规则
├── references/         每个模块一份「怎么检查、怎么装」
├── templates/          配置文件与生成物模板（内容的权威来源）
└── scripts/            只有四件事必须走脚本
    ├── hao-secret.sh   凭据生成/复用/注入 —— 值不进对话
    ├── hao-state.sh    状态与交接契约 —— 格式不能漂
    ├── hao-guard.sh    覆盖前的归属判断 —— 全只读
    └── hao-remote.sh   SSH 传输、主机指纹、远端会话 —— 密钥不进 argv
.claude-plugin/         插件与市场清单
tests/                  结构完整性 + 脚本行为测试
```

**没有 CLI 守护进程，没有安装脚本。** 部署过程写在 `references/` 里由 agent 执行；
只有密钥处理、状态写入、归属判断、远程传输这四类必须确定性的事情保留成脚本。

## 开发

```bash
./tests/run.sh                     # 全量：bash -n、shellcheck、结构与行为测试、插件校验
./tests/test-guard.sh              # 单跑某一项
HAO_TEST_REMOTE_TARGET=<别名> ./tests/test-remote.sh   # 加跑真机端到端
claude plugin validate . --strict  # 插件清单校验
claude --plugin-dir . -p "..."     # 本地加载 skill 试跑
```

CI 在每次 push 上跑 `tests/run.sh`。所有 `*.sh` 必须过
`bash -n` 与 `shellcheck -x -S warning`。

**测试覆盖的边界要说清楚**：脚本的行为有测试，`references/` 里的**过程正确性
没有自动化测试**——散文没法 shellcheck。改动过程文档后，需要在一台一次性
Ubuntu VM 上真跑一遍验证。

## 验收

只在 Ubuntu 上做验收（26.04 / 24.04 / 22.04 LTS）。Debian 13/12 仍在支持列表里，
但不作为发布门槛：GitHub 托管的 runner 没有 Debian 镜像，容器也无法真实地
验证 systemd 与 Docker。

每次验收用一台全新的一次性 VM，记录：系统镜像与架构、只读检查输出、
第一次部署结果、第二次部署结果（验证幂等）、`drift` 输出、服务健康检查、
以及销毁 VM。**验收记录里不要出现任何凭据。**

## 分发

通过插件市场分发（本仓库根的 `.claude-plugin/marketplace.json`）。
用户 `/plugin marketplace add YoungHong1992/HAO` 即可，
插件会被复制进本机 `~/.claude/plugins/cache`。

`plugin.json` 里的 `version` 是语义化版本，供插件生态的 semver 校验使用。
仓库整体就是分发单元，没有单独的发布产物。

## 许可

MIT，见 [LICENSE](LICENSE)。安全问题报告见 [SECURITY.md](SECURITY.md)。
