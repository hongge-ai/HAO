# remote —— 从本机通过 SSH 操作服务器

当 Claude Code 跑在笔记本上、目标是另一台 Debian/Ubuntu 服务器时，用这一套。
传输层只有 `scripts/hao-remote.sh`，它不含任何模块知识；装什么仍然由你在对话里
问用户决定。

## 1. 两种模式，`$SKILL` 的含义不同

| 模式 | `$SKILL` | `"$SKILL/scripts/hao-state.sh" services` 实际在哪跑 |
|---|---|---|
| 本地 | `${CLAUDE_SKILL_DIR}` | 本机 |
| 远程 | `hao-remote.sh session` 返回的远端目录 | 服务器 |

远程模式下 `exec` 会 `export SKILL=<远端目录>` 并 `cd` 进去，所以过程文档里
`"$SKILL/scripts/..."` 和模板的相对路径都原样成立——**98 处调用一个字都不用改**。

## 2. 选目标

先看登记过什么：

```bash
"$R" targets
```

没有登记过的服务器走一遍接入：

```bash
"$R" resolve <目标>        # mode/host/user/port/user_from
```

- `<目标>` 可以是 `~/.ssh/config` 里已有的别名，也可以是 `user@host`。
- 非 22 端口用 `--port`：`"$R" probe --port 46868 root@1.2.3.4`。
- 从地址形式接入时，用户必须是显式的。Windows 默认用户形如 `CORP\alice`，
  Linux 上没有这个用户，`resolve` 会直接拒绝——这不是误报，照它说的写成
  `user@host` 或先在 ssh config 里配好 `User`。
- 用户 config 里设了 `RemoteCommand` 或 `HostKeyAlias` 时同样拒绝：前者会把
  我们发的每条命令顶掉，后者会让 known_hosts 记到别处。

## 3. 主机指纹：第一次连接必须人工确认

```bash
"$R" hostkey <目标>
```

输出每一条主机密钥的 SHA256 指纹。**把 ed25519 那条念给用户，让他确认这是他
刚买的那台机器。** 用户自己的 `~/.ssh/known_hosts` 里已有同一台机器时，
`trusted=user-known-hosts`，此时可以跳过确认。

确认后：

```bash
"$R" bootstrap <目标> --fingerprint SHA256:...
```

`bootstrap` 只接受 `hostkey` 报出来的指纹。它依次做：

1. 把**匹配的那一行**写进 `~/.ssh/hao_known_hosts`（0600）。已有该主机但
   密钥不同 → **硬失败**，不覆盖。主机密钥变了意味着重装过系统或有人冒充，
   必须停下来查清。
2. 生成 `~/.ssh/hao_ed25519`（存在则原样复用，绝不覆盖）。
3. 装公钥。
4. 验证**仅密钥**能登录（禁用密码认证）。
5. 地址形式才写 `~/.ssh/config`，带 `# >>> hao-remote <别名> >>>` 标记块，幂等，
   遇到同名 Host 或同 HostName 条目会拒绝。
6. 登记到 `~/.local/state/hao/remote/targets.tsv`。

### 装公钥的两条路

**默认（推荐）**：`bootstrap` 打印一条 `ssh-copy-id` 命令，让用户在自己的终端里跑。
密码由 ssh 自己从 tty 读，HAO 从头到尾不接触。

**可选 `--askpass`**：用户先自己建一个 0600 的密码文件：

```bash
(umask 077 && printf '%s' '密码' > ~/.ssh/hao_bootstrap.pw)
```

然后 `bootstrap --askpass`。密码只以**文件路径**的形式经环境变量传给 ssh，
安装成功后脚本会删掉该文件。Linux 上检查 `stat` 权限；Windows 上 `chmod`
对 NTFS 是假的，改为检查 ACL 里有没有 Everyone/Users 这类宽泛授权。

**永远不要把密码放在命令行参数里，也不要让它出现在对话记录中。** 密码进了对话
就等于永久留在本地 transcript 并随请求发往模型服务端。

服务器禁用密码认证（`PasswordAuthentication no`）时两条路都不通，直接报错并
让用户走云厂商控制台的密钥注入，不要重试。

## 4. 确认目标：`probe`

```bash
"$R" probe <目标>
```

只读，输出 `uid / login_user / hostname / os_id / os_version / os_supported /
sudo_nopasswd / public_ip / sshd_ports / state_dir / machine_id / identity`。

**把 `hostname`、`public_ip`、`os_id os_version` 念给用户，问一句「是这台吗」。**
`identity` 是 `machine_id` 与 `public_ip` 的哈希，用来在后续会话里发现「别名
指向的机器被换掉了」。

停止条件：`os_supported=no`；`uid != 0` 且 `sudo_nopasswd` 不是 `yes`。

## 5. 建立会话

```bash
T=<目标>
SKILL="$("$R" session "$T")"
```

`session` 把 `scripts/` + `templates/` 推到服务器上的 `/tmp/hao.XXXXXXXXXX`
（0700，随机名），过三道门禁才启用：

- 三个脚本 `bash -n` 通过
- 目录里没有任何残留 `\r`（Windows 工作区是 CRLF，`set -euo pipefail\r` 在
  Linux 上会直接报非法选项）
- 树哈希与客户端一致

**stdout 只有远端路径**，进度全走 stderr，所以可以直接用 `$()` 捕获。
重复调用会复用已有的目录；服务器重启后 `/tmp` 被清掉，`session` 会检测到并重新推送。

`SKILL` 只在**同一次 Bash 调用**里有效。每个 Bash 调用都是新 shell，跨调用时
重新取一次。

## 6. 执行代码块：一个块 = 一次 `exec`

```bash
"$R" exec "$T" - <<'__HAO_BLOCK__'
<references 里的原代码块，一字不改>
__HAO_BLOCK__
```

**外层定界符必须带引号**（`<<'__HAO_BLOCK__'`）。不加引号的话 `$SKILL`、`$DOMAIN`
会在本机被提前展开成空，远端拿到的是一堆残缺命令。

**一个代码块必须包在一次 `exec` 里，不能拆开逐条跑。** 这些块依赖单进程语义：

- `claude-code.md` 的 `install -m 600` + `trap ... EXIT`（拆开会让 token 留在 0644 文件里）
- `site.md` 的 staging 发布 + `trap 'rm -rf "$STAGE"' EXIT`
- `docker.md` 的 `python3 - "$DAEMON" <<'PY'` 深合并
- `gh.md` / `uv.md` 的 `hao-state.sh convention ... <<'EOF'`（正文从 stdin 读）
- 各种 `if` / `for` / `while` / 函数定义

单条命令也可以用参数形式：

```bash
"$R" exec "$T" -- nginx -t
"$R" exec "$T" -- 'ls -d /var/lib/hao/* 2>/dev/null | wc -l'   # 单参数含元字符时按 shell 执行
```

路径翻译：以本地 skill 目录开头的参数会被换成远端路径，所以
`"$SKILL/templates/nginx-htpasswd.conf"` 在远端仍指向同一份内容。

需要交互的少数命令（`github-authorize`、`certbot delete`）用
`exec --tty "$T" -- <单行命令>`，此时不能用 heredoc。

## 7. 退出码

`exec` 原样透传远端退出码，不做任何重映射：

| 退出码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 命令自己的失败（`drift` 有漂移也是 1，别当传输错误） |
| 255 | ssh 传输失败：不可达、认证失败、主机密钥变更 |

`hao-guard.sh` 的退出码只表示「脚本跑通了」，结论在 stdout，`foreign` 也是 0。

## 8. 密钥与跨机文件

`hao-secret.sh` 的 `@file:PATH` 和 `@env:VAR` 都在**执行脚本的那台机器**上解析。
远程模式下那是服务器，所以本机上的 token 文件不会被看到。

用户给了本机文件时，先传上去再引用：

```bash
"$R" exec "$T" -- 'umask 077; cat > /tmp/hao-incoming-token'
# 上面这条从 stdin 读；把本机文件喂进去：
"$R" exec "$T" -- 'umask 077; cat > /tmp/hao-incoming-token' < "$LOCAL_TOKEN_FILE"
```

**不要把密钥值拼进 `exec` 的参数里**：那条命令会出现在本机进程的 argv 里，
同机任意用户都能通过 `ps` 看到。

## 9. 状态与交接

`/var/lib/hao` 在服务器上，由远端脚本写入——状态就在它该在的机器上。

远程模式下 `handoff` 默认加 `--skip-agent-files`：服务器上未必装了 AI 助手，
写进去的指针块没人读。`/var/lib/hao/HANDOFF.md` 才是权威交接物。

每次接到一台已经被管理过的服务器，按这个顺序起步：

```bash
"$R" probe "$T"
"$R" exec "$T" -- cat /var/lib/hao/HANDOFF.md
"$R" exec "$T" - <<'__HAO_BLOCK__'
"$SKILL/scripts/hao-state.sh" services
"$SKILL/scripts/hao-state.sh" drift || true
"$SKILL/scripts/hao-state.sh" orphans
__HAO_BLOCK__
```

（`drift` 非 0 表示有漂移，`|| true` 是为了让后面的命令继续跑。）

收尾照常：

```bash
"$R" exec "$T" - <<'__HAO_BLOCK__'
"$SKILL/scripts/hao-state.sh" handoff --user <目标用户> --skip-agent-files
__HAO_BLOCK__
```

## 10. 多台服务器

`targets` 里的条目只是清单，**永远不要自动选一台**。每次部署都按目标单独问用户，
并且先 `services` 看这台已经装了什么，只提缺口。不要把一台的模块集合照搬到另一台。

## 11. 收尾清理

```bash
"$R" cleanup "$T"          # 删本次会话的远端目录
"$R" cleanup "$T" --all    # 顺带清理一天以前遗留的目录
```

`cleanup` 只删带 `.hao-session` 标记、非符号链接、属主是登录用户的目录；任一
条件不满足就拒绝，不会 `rm -rf` 任何可疑路径。

## 12. 排错

| 现象 | 原因与处理 |
|---|---|
| `rc=255`，`Permission denied (publickey,password)` | 公钥没装上，或 `hao_ed25519` 被删了。重跑 `bootstrap` |
| `Host key verification failed` | 主机密钥与 `hao_known_hosts` 不符。**先停下查清**：重装过系统？还是有人在冒充？确认后用新的 `--fingerprint` 重新 bootstrap |
| `Too many authentication failures` | 客户端在试别的密钥。脚本已经固定 `IdentitiesOnly=yes`，出现说明 ssh config 里还有别的 `IdentityFile` |
| 远端脚本报 `set: pipefail: invalid option name` | bundle 里混进了 CRLF。检查打包流程；`session` 的门禁本该拦住它 |
| `ssh-keyscan` 报 `unsupported KEX method` | Windows 自带 OpenSSH 9.5 的 keyscan 连不上 OpenSSH 10.x。脚本会自动退回用 `ssh -v` 取指纹；Git Bash 的 ssh-keyscan 通常也能用 |
| 用户 config 里有 `StrictHostKeyChecking no` | 脚本每次显式传 `-o StrictHostKeyChecking=yes`，命令行优先，不受影响 |
| 每次命令都要等 0.5 秒 | Windows OpenSSH 不支持 ControlMaster，每次 `exec` 都是新连接。把整步包进一次 `exec`，别逐条调用 |
| `sudo: a password is required` | 目标用户不是 root 且没有免密 sudo。停下，让用户自己配 sudoers，不要改它 |
