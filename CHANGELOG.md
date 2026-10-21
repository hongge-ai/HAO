# Changelog

HAO 通过插件市场分发（`.claude-plugin/marketplace.json`）。
`plugin.json` 里的 `version` 是语义化版本，供插件生态的 semver 校验使用。

## 0.2.0 —— 远程模式

HAO 不再要求「Claude Code 必须跑在目标服务器上」。agent 可以在笔记本上通过
SSH 驱动一台或多台服务器，服务器上不装任何常驻程序。

### 新增

- `scripts/hao-remote.sh` —— 传输与认证层，九个只做一件事的子命令：
  `resolve`（别名/地址判定）、`hostkey`（只读扫描指纹）、`bootstrap`（钉死主机
  密钥 + 生成专用密钥 + 装公钥 + 仅密钥验证 + 写 ssh config）、`probe`（只读身份
  探测）、`session`（远端临时目录 + 三道落地门禁）、`push`、`exec`（命令或 stdin
  脚本）、`cleanup`、`targets`。
- `references/remote.md` —— 选目标、指纹确认、两条装公钥路径、包裹规则、退出码
  语义、远程下的状态与交接、排错表。
- `tests/test-remote.sh` —— 离线行为测试（假 ssh 桩），真机端到端用
  `HAO_TEST_REMOTE_TARGET` opt-in。
- 专用密钥 `~/.ssh/hao_ed25519` 与独立 `~/.ssh/hao_known_hosts`，不复用用户个人密钥，
  也不污染用户的 known_hosts。

### 改变

- `SKILL.md` 的「前提：你必须在目标服务器上」改为「0. 先确定操作哪台机器」，
  本地/远程两条路径并列；新增「一个代码块 = 一次 exec」硬规则；意图表从
  「安装清单」降级为「组织提问的候选」；硬规则增至六条。
- 远程模式下 `handoff` 默认加 `--skip-agent-files`，`/var/lib/hao/HANDOFF.md`
  是权威交接物。
- 仓库地址同步到 `hongge-ai/HAO`。

## 0.1.0（未发布）—— 初始版本

第一个版本，尚未对外发布过。在这之前，仓库经历过一次形态上的重写（从一套约
15000 行的 CLI 改成 agent 直接执行的 skill）和若干轮设计收敛，那些过程记录对使用者
没有意义，已经删掉——没有任何存量安装需要照顾。这里只写**这个版本是什么样**。

### 形态

HAO 不是命令行工具，是一套**给 AI agent 用的部署知识**：

- `skills/hao-deploy/SKILL.md` —— 入口：意图→模块映射，六步流程
  （问清 → 只读检查 → 讲清楚并确认 → 照 reference 执行 → 拿真实证据验证 →
  记录状态并交接），以及硬规则。
- `references/<模块>.md` —— 一个模块一份过程文档，承载不显然的运维知识：
  确切命令、顺序约束、拒绝条件，以及每条背后的理由。
- `templates/` —— 所有写到主机上的多行文件的权威内容，占位符是 `@@TOKEN@@`，
  每个模板头部列出自己的全部占位符。**每个占位符的值必须是单行**：占位符本身也
  写在模板的注释头里，替换是整文件范围的，多行值会从注释里漏出来变成活配置。
  所以"要填一段配置"的地方都是一行 include（80 端口跳转用
  `snippets/redirect-to-https.conf`）或一个词。
- `scripts/` —— 只有三件事保持确定性，因为即兴发挥会破坏某个保证：
  `hao-secret.sh`（凭据生成/复用/注入，值不进对话、不进 argv）、
  `hao-state.sh`（状态与交接契约，含 `amend` / `orphans` 两条给"记录不可信"
  兜底的子命令）、`hao-guard.sh`（覆盖前的只读归属判断）。
  （0.2.0 起增加第四个：`hao-remote.sh`，见上。）

安装：

```
/plugin marketplace add YoungHong1992/HAO
/plugin install hao@hao
```

### 13 个模块，一个工具一个模块

`fail2ban`、`swap`、`journald`、`nginx`、`docker`、`node`、`uv`、`claude-code`、
`git`、`gh`、`site`、`nginx-hardening`、`fail2ban-nginx`。

捆绑关系放在 `SKILL.md` 的意图映射表里，不放进 reference：用户说"服务器刚买来先弄
安全点"，agent 一次装齐 `fail2ban` + `swap` + `journald`，但三者各记一条状态、
各自独立查漂移、可以单独卸载。这条不变量是有代价换来的：`hao-state.sh record`
按 service ID **整体替换**，把几个工具塞进一条记录就等于放弃了单独卸载和单独
查漂移的能力。

### 主机上用业内通用的路径和工具

源码 `/opt/<站点ID>`、静态产物 `/var/www/<域名>`、vhost
`/etc/nginx/conf.d/<域名>.conf`、systemd 单元 `<站点ID>.service`、更新脚本
`/usr/local/bin/<站点ID>-update`、证书由 **certbot** 签在
`/etc/letsencrypt/live/<域名>/`。**主产物都不带 `hao-` 前缀** —— 一个没听说过 HAO
的运维登上机器，在他习惯的位置就能找到东西；只有 HAO 能维护的布局等于把用户锁死。

标识只留在**文件内部的注释头**（`# Managed by HAO` / `# Service:` /
`# HAO-SITE:`）。`hao-guard.sh` 读文件内容而不是文件名，所以通用命名不花代价——
但那几行注释一行都不能删。

两类例外：`/var/lib/hao`（状态）与 `/etc/hao`（凭据）是 `/var/lib/<工具名>`、
`/etc/<工具名>` 的约定本身；`*.d/` 目录下的 drop-in 带来源前缀
（`jail.d/hao-sshd.local` 之类），因为共享目录里放一个能看出出处的文件名本来就是惯例。

### 交接契约：机器可以扔，知识不能丢

状态写在**主机上**而不是留在聊天记录里：`/var/lib/hao/` 下有 `HANDOFF.md`
（给下一个 agent）、`DEPLOY-INTENT.md`（给用户带走的重放依据，0644，不含凭据）、
`manifest.json`（资源清单，含归属类别与内容哈希）、`services/<svc>.*`。
`handoff` 还会把指针块写进本机 AI 助手的指令文件——下一个 agent 不需要被谁告知，
开机就知道这台机器由 HAO 管理。

归属分四级（`managed` / `shared` / `observed` / `secret`）决定后来的 agent 能对一个
资源做什么。选错有具体代价：把用户的代码目录记成 `managed`，`drift` 会永久误报；
把别人的配置记成 `managed`，下一个 agent 会理所当然地覆盖它。

凭据与状态分开放，判据是**可再生性**：`/var/lib` 按惯例是可丢弃的再生状态，
备份策略经常整体排除它；凭据不可再生（重新生成等于换密码），所以在 `/etc/hao`
（文件 0600，目录新建时 0700）。

### 安全契约

- 改系统之前先用普通话讲清楚并取得确认；只读检查不需要确认。
- 归属检查返回 `foreign` / `not-git` / `remote-mismatch` / `other <issuer>`
  一律停下，绝不覆盖别人的东西。
- 密钥值不进对话、不进日志、**不进命令行参数**（argv 对同机任意用户可见）。
  用户自带密钥走 `@file:`，`hao-secret.sh` 直接拒绝字面量。
- 幂等：重跑不换线上凭据、不重复申请证书、不每次换端口；清空/覆盖之前先校验新内容。
- 如实汇报：失败说失败，降级说降级，没生效说没生效。

### 范围边界

只装**通用的运维底座** + 从用户自己的仓库部署站点。具体第三方应用的部署过程
**不在范围内**——它们各有自己的初始化流程、默认口令和数据迁移语义，写成通用过程
只会给出似是而非的步骤。`SKILL.md` 给了一份必查清单（默认管理员口令、数据在哪、
镜像 tag 固定、容器端口绑回环）供 agent 照上游文档部署时使用。

证书只用 `certbot certonly`，**不装 `python3-certbot-nginx`**：那个插件会改写
nginx 配置、和模板打架。由此有一条容易踩的坑写进了模板注释与测试——
`/etc/letsencrypt/options-ssl-nginx.conf` 和 `ssl-dhparams.pem` 由那个插件提供，
在只装 certbot 的机器上永远不存在，vhost 里 include 它们会让 `nginx -t` 在证书
**签发成功之后**失败。所有 TLS 参数都在 `snippets/ssl-hardening.conf` 里。

### 测试与验收

`./tests/run.sh`：`bash -n`、`shellcheck -x -S warning`、skill 结构完整性
（frontmatter、悬空引用、模板占位符必须在自己注释里有说明、模板不得引用 certbot
插件的文件、每个模块必须以 `handoff` 收尾、代码块里不得出现会和环境变量撞名的
`$USER`）、三个脚本的行为测试、渲染后真的执行一遍站点更新脚本（含"产物目录填错"
和"发布中途失败"两个分支，验证线上内容不被破坏）、把 nginx 模板渲染进临时 prefix
交给**真的 `nginx -t`**（这是唯一能发现"某个指令在这个 nginx 版本上不存在"的办法，
装了 nginx 才跑，没装就跳过）、插件清单校验。

**过程文档的正确性没有自动化测试**——散文没法 shellcheck。改动 `references/` 后
需要在一次性 Ubuntu VM 上手工验证，见 README 的「验收」一节。
验收只在 Ubuntu 上做：GitHub 托管的 runner 没有 Debian 镜像，容器里也无法真实
验证 systemd/Docker。
