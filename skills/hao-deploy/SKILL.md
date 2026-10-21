---
name: hao-deploy
description: 在 Debian/Ubuntu 服务器上部署网站和开发运维工具，面向不懂运维的用户。可以从本机通过 SSH 远程操作，也可以直接在服务器上运行。当用户想把自己的 Git 仓库变成能访问的网站、想在 VPS 上装 Nginx/Docker/Node 等工具、想初始化一台新买的服务器、想查询服务器状态、想更新或排查已部署的站点、或者接手一台别人（或以前的自己）部署过的服务器时使用。
when_to_use: 用户说"帮我把这个仓库部署上线""在服务器上装个 nginx""连上我那台服务器看看""把这台新机器初始化一下""我的站点打不开了""这台机器上装了什么""接手一下这台服务器"时触发。也适用于用户刚买了一台 VPS、想搭一个能干活或学习的环境。
allowed-tools:
  - Bash(${CLAUDE_SKILL_DIR}/scripts/hao-guard.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/hao-secret.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/hao-state.sh:*)
  - Bash(${CLAUDE_SKILL_DIR}/scripts/hao-remote.sh:*)
---

# HAO 部署

把一台干净的 Debian/Ubuntu 服务器变成能用的东西：一个上线的网站，或者一台能
干活、能学习的机器。用户通常不懂运维，**你是执行者**，他只负责回答问题和拍板。

开始前先记下 skill 目录，后面所有脚本和模板都在这里：

```bash
SKILL="${CLAUDE_SKILL_DIR}"
```

（这一行里的 `${CLAUDE_SKILL_DIR}` 在加载时就被替换成真实绝对路径，所以你看到的是
一个具体目录。权限白名单按脚本的绝对路径匹配，用 `$SKILL/...` 调用是对的；
第一次调用某个脚本时可能弹一次授权，那不是出错。）

## 0. 先确定操作哪台机器

有两种模式，开局必须先选一个，并把选中的那台念给用户确认：

| 模式 | 什么时候用 | `$SKILL` 指向 |
|---|---|---|
| **本地** | Claude Code 就跑在这台 Debian/Ubuntu 服务器上 | `${CLAUDE_SKILL_DIR}` |
| **远程** | 你在笔记本上，要操作一台 VPS | 远端临时目录（`hao-remote.sh session` 返回） |

**远程模式是这个 skill 的常规用法。** 用户说到某台服务器时，先看
`hao-remote.sh targets` 里有没有登记过；有就直接用那个别名，没有就走
`references/remote.md` 的接入流程（扫描主机指纹 → 确认 → 装专用公钥）。

### 本地模式

```bash
"$SKILL/scripts/hao-guard.sh" os-supported     # 输出 "<id> <version> supported|unsupported"
id -u                                          # 期望 0
curl -s --max-time 5 https://api.ipify.org     # 这台机器的公网 IP
```

### 远程模式

```bash
R="$SKILL/scripts/hao-remote.sh"
"$R" targets                                   # 已经登记过哪些服务器
"$R" resolve <目标>                            # 别名还是地址、host/user/port
"$R" probe <目标>                              # 只读：系统、uid、公网 IP、身份哈希
```

然后：

```bash
SKILL="$("$R" session <目标>)"                 # 建立远端会话，stdout 只有路径
```

`session` 会把 `scripts/` 与 `templates/` 推到服务器上的临时目录，过三道门禁
（脚本可解析、无 CRLF、树哈希一致）后才启用。**此后所有代码块都要这样执行：**

```bash
"$R" exec <目标> - <<'__HAO_BLOCK__'
<原代码块，一字不改；块内的 $SKILL 由远端展开>
__HAO_BLOCK__
```

### 两边都要满足的停止条件

- **不是 root，且 `sudo -n true` 也不通** → 停下。装包、写 `/etc`、改 systemd 都要 root。
- `os_supported` / `os-supported` 不是 `supported` → 停下。支持 Debian 13/12 与
  Ubuntu 26.04/24.04/22.04 LTS，别的系统不要硬上。
  （本地版的输出是三段，判断要匹配结尾：`case "$(...)" in *" supported") ;; *) 停 ;; esac`。）
- **目标不是用户以为的那台机器** → 停下。远程模式把 `probe` 里的 `hostname`、
  `public_ip`、`machine_id` 念给用户确认；本地模式念公网 IP。
  `hostname` 单独一项是问不出这件事的：笔记本和 VPS 的 hostname 长得一样。

**为什么远程模式必须先确认机器**：三个 guard 脚本在「错的机器」上全部返回
放行值——`vhost-owner` 说 `free`、`managed-file` 说 `missing`、`repo-identity` 说
`absent`、`unit-free` 说 `free`，`record` 会静默跳过不存在的路径，`remove` 会
直接删记录。它们只能回答「我看得见的这台机器」，看不出来你盯错了。钉死的主机
密钥加上开机确认，是唯一能拦住这件事的两道控制。

## 工作流程

### 1. 先弄清用户到底要什么

用户说的是目标（"我想让我的博客上线"），不是服务清单。这张表只用来**组织提问**，
不是安装清单：

| 用户想要 | 候选模块 |
|---|---|
| 让我的网站/博客上线 | `nginx` + `site`（node 类型再加 `node`） |
| 我要一台能跑 AI 工具的机器 | `node` + `uv` + `claude-code` |
| 我要跑容器化的服务 | `docker`（+ `nginx` 做反代） |
| 服务器刚买来，先弄安全点 | `fail2ban` + `swap` + `journald` |
| 我要给站点防扫站/防爆破 | `nginx-hardening` + `fail2ban-nginx`（站点在 CF 后面时连边缘那步一起给用户） |
| 我要在服务器上用 git / GitHub | `git` + `gh` |

**候选不等于决定。** 把候选连同全部模块用一行一项列出来（名称 + 作用 + 大致
耗时），明确问「你要装哪几个」，等用户勾选后才动手。用户没点名的模块不装，
包括「顺手装一下也不费事」的那种。用户拒绝的候选记一条 `skipped`。

同一台机器分多次来装时，先跑 `services` 看已经有什么，只提缺口，不要把上一次
的模块集合照搬。多台服务器同理：每台单独问。

问清缺失的关键信息，一次问完，不要来回挤牙膏。各模块要问什么，看对应的
reference。**不要替用户猜域名、Git 身份、仓库地址这类东西。**

### 2. 只读检查

动手前把该查的都查完（这些命令都是只读的，随便跑）：

```bash
"$SKILL/scripts/hao-state.sh" services     # 这台机器已经装了什么
"$SKILL/scripts/hao-state.sh" drift        # 有没有被手工改过（只查 managed 资源）
"$SKILL/scripts/hao-state.sh" orphans      # 有没有 HAO 写过却没记录的文件
"$SKILL/scripts/hao-guard.sh" ...          # 目标资源归属，见各 reference
```

`drift` 有漂移时**退出码非 0**，所以别写成 `drift && 下一步`。它也只比对 `managed`
资源：`shared` / `observed` / `secret` 不参与，"drift 干净"的意思是"HAO 自己写的
文件没被动过"，不等于"这台机器没被动过"。

如果 `services` 显示这台机器已经被 HAO 管理过，先读
`/var/lib/hao/HANDOFF.md`，再看 `references/handoff.md` 的接手流程。那里有四条
互不重叠的对账（记录可信吗 / 文件被改过吗 / 有没有漏记 / 记录说装了的真的在吗）——
**`installed` 不等于真的能用**，`record` 只检查它列出的路径存在，不检查服务本身。

### 3. 讲清楚，然后拿到确认

把将要发生的系统变更用普通话讲一遍再动手。用户是小白，他无法从命令里看出
风险，这一步是他唯一的保护。具体要求见 `references/safety.md`。

### 4. 按 reference 执行

一个模块一份过程文档，照着做，不要凭记忆：

| 模块 | 文档 | 作用 |
|---|---|---|
| `fail2ban` | `references/fail2ban.md` | SSH 防爆破（自动探测真实 SSH 端口） |
| `swap` | `references/swap.md` | swap 文件 + 换出倾向调优 |
| `journald` | `references/journald.md` | 系统日志占用上限 |
| `nginx` | `references/nginx.md` | Nginx（nginx.org 源，含 HTTP/3）+ 内核调优 |
| `docker` | `references/docker.md` | Docker Engine + Compose 插件 + 容器日志轮转 |
| `node` | `references/node.md` | 系统级 Node.js LTS（落在 `/usr/bin`） |
| `uv` | `references/uv.md` | uv Python 管理器 + Python 使用约定 |
| `claude-code` | `references/claude-code.md` | Claude Code CLI + 网关/模型配置 |
| `git` | `references/git.md` | Git + 提交身份 |
| `gh` | `references/gh.md` | GitHub CLI + 授权助手 + gh 操作约定 |
| `site` | `references/site.md` | 从 Git 仓库部署静态站或 Node 站，含证书 |
| `nginx-hardening` | `references/nginx-hardening.md` | 站点防护基线：真实 IP 还原、扫站/恶意 UA 拦截、限流、安全响应头 |
| `fail2ban-nginx` | `references/fail2ban-nginx.md` | 站点扫站（403/404）与后台爆破的自动封禁 |

**一个工具一个模块。** 用户要的往往是好几个（意图表就是干这个的），但每个模块
自己是独立的：独立安装、独立 `record`、独立 drift、独立卸载。装三件加固时其中
一件失败，另外两件照做，如实汇报哪件没成。

另外几份跨模块文档：

- `references/remote.md` —— 远程模式：选目标、主机指纹、装公钥、会话与 `exec` 包裹规则（远程模式开场必读）
- `references/handoff.md` —— 状态记录格式与交接契约（收尾必读）
- `references/safety.md` —— 完整安全契约
- `references/uninstall.md` —— 卸载流程。**只在用户明确要求时才读它**

配置文件内容在 `templates/`，把 `@@TOKEN@@` 换成实际值再写入。**模板是内容的
权威来源**，里面每一行都有原因，不要自己重写一份"差不多的"。每个模板的头部注释
列了它自己的全部占位符；**写完必须 `grep -n '@@[A-Z]' <文件>` 确认没有残留**——
漏一个不只是配置不对，`@@SITE_ID@@` 残留会毒化归属判断（见 `references/site.md` 第 4 节）。

**每个占位符的值都必须是单行。** 占位符本身也写在模板的注释头里，而替换是整个
文件范围的：填一个多行值进去，第一行还留在注释里、后面几行就变成了活配置，
落在任何 server 块 / systemd 段之外，报出来的错和真正的原因毫不相关。所以那些
"要填一段配置"的地方都设计成了一行 include 或一个词（`@@PORT80_BODY@@`、
`@@DEFAULT@@`、`@@EXTRA_ENV@@`）。

少数只有一行的东西（apt 源那几行、`/etc/fstab` 里的 swap 行）没有单独的模板，
内容在对应 reference 里逐字给出。

现有模板都不含密钥；一旦要写入含密钥的配置，用 `hao-secret.sh render` 渲染，
不要自己读出密钥再拼进去。render 是**全有或全无**（模板里每个 `@@KEY@@` 都必须在
凭据文件里，所以结构性占位符要先自己替换掉），默认权限 **0640**，
输出含密钥时要显式 `--mode 0600`。

### 主机上的路径一律用通用形式

写到主机上的东西必须让**不知道 HAO 存在的运维人员**也能维护：源码在
`/opt/<站点ID>`，静态产物在 `/var/www/<域名>`，vhost 在
`/etc/nginx/conf.d/<域名>.conf`，systemd 单元叫 `<站点ID>.service`，
更新脚本叫 `/usr/local/bin/<站点ID>-update`，证书由 certbot 签在
`/etc/letsencrypt/live/<域名>/`。**这些主产物都不带 `hao-` 前缀。**
完整路径表和理由见 `references/site.md` 开头。

唯一保留 HAO 标识的地方是**文件内部的注释头**（`# Managed by HAO` /
`# Service:` / `# HAO-SITE:`）。`hao-guard.sh` 靠它判断归属，读的是文件内容不是
文件名，所以通用命名不花任何代价——但**那几行注释一行都不能删**。

两类例外，都不是"忘了改"：

- `/var/lib/hao`（状态）和 `/etc/hao`（凭据）—— `/var/lib/<工具名>`、
  `/etc/<工具名>` 正是约定本身，同 `/var/lib/docker`、`/etc/docker`。
- **`*.d/` 目录里的 drop-in 片段带来源前缀**：`/etc/fail2ban/jail.d/hao-sshd.local`、
  `/etc/sysctl.d/99-hao-swap.conf`、`/etc/security/limits.d/90-hao-nofile.conf`、
  `/etc/systemd/journald.conf.d/hao.conf`。共享目录里放一个能看出出处的文件名
  本身就是惯例（`50-cloud-init.cfg` 之类），对接手的人是帮助。新增 drop-in 沿用
  这个风格，别再发明第三种。

### 不在本 skill 范围内的事

HAO 只装**通用的运维底座**：Web 服务器、运行时、容器引擎、基础加固，以及从
用户自己的 Git 仓库部署站点。**具体第三方应用的部署过程不在这里**（模型网关、
论坛、面板这类）——它们各有自己的初始化流程、默认口令和数据迁移语义，
写成通用过程只会给出似是而非的步骤。

用户要装某个具体应用时：照 `docker` + `nginx` 打好底座，然后**按上游官方文档
部署**，并把这几件事当成必查项：

- 上游有没有**默认管理员口令**？有就必须在暴露到公网之前改掉，
  并在汇报里单独说这一条。
- 配置文件或 compose 里要填密码？用 `hao-secret.sh write` 生成、
  `hao-secret.sh render` 注入（模板里写 `@@KEY@@`），别把值读出来拼进去。
- **它自己有没有记着对外地址？** 公开地址 / 站点 URL、允许来源（Origin / Referer
  白名单）、CORS、OAuth 回调、Cookie 的 `Secure` 位、CSRF 的信任来源、TrustedHost。
  这些可能由应用自身配置，换域名或换协议时要按上游文档同步检查；漏改的现象是**首页正常、
  一登录/一提交就报错**。理由与做法见 `references/site.md` 的「来源校验教训」。
- **它有哪些启动校验和反代要求？** 按上游文档检查公开 URL、必需密钥、
  TLS 终止方式、转发头和可信代理配置。应用内部监听 HTTP，也可以由 Nginx 对外
  提供 HTTPS；应用需要正确识别原始请求的协议与地址。确认配置兼容后再启用跳转，
  若不兼容，说明限制并让用户决定方案，不自动改为明文部署。
- 数据在哪（bind mount 还是 named volume）？销毁机器前要导出什么？
- 镜像 tag 别用 `latest`，让用户去上游 releases 挑一个固定 tag——
  否则同一份步骤两周后装出来的东西不一样。部署前用
  `docker manifest inspect <image>:<tag>` 确认 tag 还在，拉不到就停下来问用户，
  不要默默换一个。
- 容器端口一律绑 `127.0.0.1`，对外只走 Nginx 反代。宿主机端口用
  `hao-guard.sh port-free <端口>` 挑（只接受 `free`，`unknown` 表示查不了）；
  **占端口的常常不是容器而是 systemd 服务**，默认端口撞上它很常见。
- 服务目录放 `/opt/<服务名>`，和站点源码同一套约定。

反代和证书照 `references/site.md` 第 4 节做（含 certbot 签发；续期钩子由 nginx
模块安装），模板里的占位符按那一节的总表全部替换掉，写完 `grep -n '@@[A-Z]'` 查一遍。
收尾同样要 `hao-state.sh record` + `intent` + `handoff`。

### 5. 验证

每一步都要拿到真实证据，不要因为命令退出码是 0 就报成功：

- 服务：`systemctl is-active`，以及端口真的在监听
- Nginx：`nginx -t` 通过，且 reload 成功
- 站点：**真的取一次内容**（`curl -sS -o /dev/null -w '%{http_code}' -H "Host: $DOMAIN" http://127.0.0.1/`），
  不是 2xx/3xx 就停下
- **反代的是应用时，还要验证实际交互流程**：首页 200 不能证明登录或提交可用。
  对提供 POST 等非 GET 接口的应用，通过公开 URL，按其要求携带 Origin / Referer、
  Cookie 和 CSRF token 做受控验证；具体步骤见 `references/site.md` 的「来源校验教训」。
  按预期响应和应用日志判断，不能仅凭没有来源 / CSRF 类 403 就判定通过。
  无法完成的流程要如实标为未验证
- 探测结果**隔一两秒复测一次再下结论**：`systemctl reload nginx` 是优雅切换，
  已有连接上的请求可能仍由旧 worker 按改动前的配置应答。复测时建立新连接，
  确认响应符合新配置；结果不一致时继续检查 reload 和错误日志，不把固定等待时间
  当作配置已经生效的保证
- 调优项：回读实际生效值（例如 BBR 要看 `sysctl -n net.ipv4.tcp_congestion_control`）

失败就停下来如实汇报，把原始输出给用户。

### 6. 记录状态并交接（不可跳过）

```bash
"$SKILL/scripts/hao-state.sh" record <service> <result> OWNERSHIP:PATH ...
"$SKILL/scripts/hao-state.sh" intent <service> key=value ...    # 用户给的那些回答
"$SKILL/scripts/hao-state.sh" handoff --user <目标用户>
```

这一步是整个 skill 存在的理由之一：机器和会话都是即用即抛的，只有主机上的
记录能让下一个 agent 接手。归属类别怎么选、`<result>` 五个词怎么选、
`--user` 为什么不能省（默认是 `${SUDO_USER:-root}`，以 root 直跑时指针块只会写进
`/root`），都见 `references/handoff.md`。

**远程模式下 `handoff` 还要加 `--skip-agent-files`**：服务器上未必装了 AI 助手，
写进去的指针块没人读。权威交接物是服务器上的 `/var/lib/hao/HANDOFF.md`，下一次
远程会话用 `exec cat /var/lib/hao/HANDOFF.md` 取。详见 `references/remote.md`。

`record` 记的是**这台机器现在是什么样**（资源路径、归属、哈希），机器销毁就没了；
它会静默跳过不存在的路径并打印一行"跳过"——那行是证据，说明某一步没做成。
`intent` 记的是**怎么再造一台一样的**（用户给的那些回答），**一个 service ID
只有一条记录**（`record` 是整体替换），所以能部署多份的东西必须带实例标识
（`site-blog` 而不是 `site`）。这两条的完整理由在 `references/handoff.md`。

## 四个必须走脚本的地方

其余步骤你直接用 shell 命令做就行。只有这四类事情不能即兴发挥：

| 脚本 | 为什么不能自己来 | 退出码怎么读 |
|---|---|---|
| `scripts/hao-secret.sh` | 密钥值绝不能进入对话记录。它负责生成、复用、注入，你只看到路径和 key 名 | `has` 的退出码就是答案 |
| `scripts/hao-state.sh` | 下一个 agent 要能**信任**状态记录。格式漂了，交接契约就废了 | `drift` 非 0 = 有漂移，别用 `&&` 串 |
| `scripts/hao-guard.sh` | 覆盖前的归属判断。全部只读，返回 `foreign` 就必须停 | 只表示脚本跑通了；结论在 stdout，`foreign` 也是 0 |
| `scripts/hao-remote.sh` | 远程传输、主机指纹、会话生命周期。密钥不进 argv、远端摘要过期、目标身份这几件事不能靠即兴拼接 | 透传远端退出码；`255` = 传输失败 |

四个脚本都支持 `-h` 查看用法。

## 硬规则

完整版见 `references/safety.md`，最关键的六条：

1. **改系统之前先讲清楚并取得确认**，只读检查不需要确认。
2. **`foreign` / `not-git` / `remote-mismatch` / `other <issuer>` 一律停下**，
   绝不覆盖别人的东西，绝不 `rm -rf` 用户的目录。
3. **凭据只报路径**，永不打印内容；用户自带密钥走 `@file:`（`@env:` 见
   `references/safety.md` 的说明），不要放进命令行参数。
4. **如实汇报**。失败说失败，降级说降级，没生效说没生效。
5. **用户没点名的模块不装。** 意图表只用来组织提问，不是清单；包括「顺手
   装一下也不费事」的那种。
6. **远程模式下，目标身份没经用户确认之前不做任何写入。** 首次连接要念
   `probe` 的 hostname / 公网 IP / 系统版本；主机密钥对不上就是硬失败，
   不要「更新一下 known_hosts」。

## 收尾汇报

用普通话告一段，不要甩路径清单。至少包含：能怎么访问、之后怎么更新、
凭据文件在哪（只有路径）、有哪些需要他自己去做的事（比如放行 443 端口、
改 DNS）。

**还要让用户把 `/var/lib/hao/DEPLOY-INTENT.md` 存一份到自己的笔记或仓库里。**
那份文件是 `intent` 生成的，装着这次部署的全部回答（仓库地址、域名、类型、
分支、构建命令），不含密钥。`/var/lib/hao` 会随机器一起消失，只留在那里等于
没留。有了它，在新机器上重放一遍就能得到等价的部署。

机器是用完就销毁的话，另外提醒：需要保留的旧密码得在销毁前自己从凭据文件导出
（`hao-state.sh credentials` 给路径，内容他自己去取），新机器上会重新生成。
