# nginx-hardening —— 站点防护基线（防扫站/限流/安全响应头）

公网机器从站点上线当天就会被自动扫描：`.env`/`.git` 探测、WordPress 路径、
攻击工具 UA、直连源站的高频抓取（真实案例：CF 统计 24h 内 1.71k 请求里
1.34k 是 4xx；单 IP 直连源站一分钟 370 次）。这个模块给装了 nginx 的机器
一层通用基线，全部写进 nginx 自己，不动应用：

```
按真实客户端 IP 还原 → 扫站路径/恶意 UA 拦截(403) → 洪峰限流(429) → 安全响应头
```

把反复扫描的 IP 直接封掉是另一个模块：`fail2ban-nginx`。两者独立安装、
独立记录；封禁 jail 的 **403** 计数靠本模块的拦截产生，没装本模块时 jail
也能靠 404 抓扫描器，只是钝一些。jail **不数 429**——限流是毫秒级自愈的软
控制，封禁是 24 小时的硬控制，把前者接到后者上会让正常访客的首屏并发凑够
封禁阈值（理由写在 `templates/fail2ban-nginx-scan.conf` 头部）。

## 0. 先讲清楚什么防不了（诚实边界）

| 层 | 防什么 | 防不了什么 |
|---|---|---|
| nginx 拦截/限流 | 扫站路径、恶意 UA、单 IP 超频 | 放慢速度的低频爬取；不封 IP |
| fail2ban（另一个模块） | 直连源站的攻击者，socket 级封掉 | **经 Cloudflare 代理的攻击**——真实 IP 不直连源站，封不到 |
| CF 边缘（用户自己配，见附录） | 经 CF 的攻击在到达源站之前拦下 | 需要用户有 CF 账号去后台点；agent 没有凭据不代劳 |

站点在不在 Cloudflare 后面**不改变**本模块写什么文件（CF 网段还原对非 CF
机器是无害的死配置），改变的是验证的解释和要不要做附录那步——所以要问。

## 1. 前置检查（只读）

前提：`nginx` 模块已装且健康（本模块的三个文件都要被 /etc/nginx include）。

```bash
nginx -v 2>&1 && systemctl is-active nginx
# realip 模块必查：整个基线的第一件事就是 real_ip_header，而 nginx **默认不
# 构建**这个模块。缺了它，文件一写进 conf.d，nginx -t 就是
# unknown directive "real_ip_header" —— 源码编译的 nginx / OpenResty 上真会遇到。
nginx -V 2>&1 | tr ' ' '\n' | grep -q http_realip_module \
    && echo "realip: ok" || echo "realip: 缺失，停下来问用户"
# worker 跑在哪个用户下（第 4 节 chgrp 要用；nginx.org 包是 nginx，发行版是 www-data）
nginx -T 2>/dev/null | awk '$1 == "user" { gsub(/;/, "", $2); print "worker user:", $2; exit }'
"$SKILL/scripts/hao-guard.sh" managed-file /etc/nginx/conf.d/00-hao-hardening.conf
"$SKILL/scripts/hao-guard.sh" managed-file /etc/nginx/snippets/scanner-blocks.conf
"$SKILL/scripts/hao-guard.sh" managed-file /etc/nginx/snippets/security-headers.conf
ls /etc/nginx/conf.d/
```

- `managed-file` 返回 `foreign` → 拒绝覆盖，报给用户。
- **realip 模块缺失** → 停下来。不要硬写进去再看 `nginx -t` 报错：那时
  conf.d 里已经有一个坏文件，reload 会失败，整机的 nginx 都受影响。
- 顺手看一眼 conf.d 里有没有**别人的** http 级配置在定义同名东西
  （`limit_req_zone`、`map`）：有冲突就停下来问用户，
  两套限流合并不是本模块的事。

问用户两件事，记进 intent：

1. 站点过 Cloudflare 吗？
2. 有没有带管理后台的站点要上 Basic Auth 网关（第 4 节）？

## 2. 写三个文件

| 模板 | 目标路径 |
|---|---|
| `templates/nginx-hardening-baseline.conf` | `/etc/nginx/conf.d/00-hao-hardening.conf` |
| `templates/nginx-scanner-blocks.conf` | `/etc/nginx/snippets/scanner-blocks.conf` |
| `templates/nginx-security-headers.conf` | `/etc/nginx/snippets/security-headers.conf` |

三个模板都**没有占位符**，逐字写入，不要"顺手优化"。两个命名都不是随意的：

- `00-` 前缀保证它在 conf.d 里最先被解析——`limit_req_zone` 必须先于引用
  它的 server 块存在，删掉前缀 nginx -t 会报 zero size shared memory zone。
- `scanner-blocks` / `security-headers` 这两个名字被站点内容块的
  **glob include**（`scanner-blocks*.conf`）引用，改名等于全站断线。

写入用备份-`nginx -t`-失败回滚的完整姿势，见 `references/site.md` 第 4 节
那段（备份不要留在 conf.d/snippets 里）。收尾：

```bash
nginx -t && systemctl reload nginx
```

## 3. 站点怎么接入（装完不等于生效）

拦截/限流/响应头都发生在 **server 级**，靠站点内容块里的两行 glob include：

```
include /etc/nginx/snippets/scanner-blocks*.conf;
include /etc/nginx/snippets/security-headers*.conf;
```

- **本模块装完之后新部署的站点**：自动生效。site 模块的两个 body 模板
  （`site-body-static.conf` / `site-body-node.conf`）已经带了这两行；glob
  无匹配时整行等于不存在，所以 body 模板并不依赖本模块。
- **装之前已经部署的站点**：内容块里没有那两行。把这两行补进该站点的
  `/etc/nginx/snippets/<CONF_NAME>.conf`（**加在现有 location 之前**——正则
  location 按出现顺序取第一个命中，排在前面，扫描 403 才由 scanner-blocks
  记账，fail2ban 才数得到；站点自带的 `location ~ /\. { deny all; }` 不用删，
  它继续兜底），然后 `nginx -t && systemctl reload nginx`。
  改的是该站点自己的 managed 文件，要**原样重跑该站点的 record** 刷新哈希，
  否则 drift 从此天天报警。原样意味着不能凭记忆重敲——`record` 是整体替换，
  且**静默跳过不存在的路径**，一个 typo 就把该站点的 systemd 单元或更新脚本
  从记录里悄悄删掉。清单从状态目录里读回来（**不是** `hao-state.sh ownership`，
  那个子命令只返回一个归属词，不是列表）：

  ```bash
  cat /var/lib/hao/services/site-<ID>.resources    # 每行一条 类别:路径
  ```

  照这份清单原样重跑 `hao-state.sh record site-<ID> updated <每一行>`，
  完整写法见 `references/site.md` 第 6 节。

- **已部署站点的 `:80` server 块必须检查是否有 `acme-challenge.conf` include。**
  旧版 `scanner-blocks.conf` 用 `(?!well-known/)` 例外放行 ACME 路径；新版依赖
  vhost 里的 `^~` 前缀 location 抢在正则之前接走——`^~` 命中后 nginx 不再试正则，
  ACME 路径就不会被 `location ~ /\.` 的 403 拦住。site 模块生成的 vhost 已经有
  `include /etc/nginx/snippets/acme-challenge.conf;`，但手写的或模块外管理的 vhost
  可能没有。**漏补的后果是证书续期静默失败**（certbot 能签发，但 80 上的验证请求
  会 403，而不是 404）——用下面这条验证每个站点：

  ```bash
  # 期望 404，绝不能是 403
  curl -s -o /dev/null -w '%{http_code}\n' -H "Host: <DOMAIN>" \
      http://127.0.0.1/.well-known/acme-challenge/probe
  ```

  如果返回 403，在该 vhost 的 `:80` server 块里、`scanner-blocks` include **之前**
  加一行：

  ```nginx
  include /etc/nginx/snippets/acme-challenge.conf;
  ```

  然后 `nginx -t && systemctl reload nginx`，重跑 `certbot renew --dry-run --cert-name <域名>` 确认续期可以过。

## 4. 可选：后台 Basic Auth 网关

给带管理后台的 Node 站点在应用登录之外加一道门：私密路径 + Basic Auth +
5 r/s 限速。错 8 次/10 分钟就被 `hao-nginx-auth` jail 封 24 小时。

**前提：该站点已经有真证书、80 端口是跳转到 HTTPS 的。** Basic Auth 每个请求
都把口令 base64（不是加密）发一遍；自签证书那条分支下内容块会被 :80 的
server 也 include，网关就在明文 HTTP 上应答了。证书没办好之前不要加这道门。

```bash
# 1. 口令落盘（值不进对话）。凭据文件名 = service ID，见 AGENTS.md 的 /etc/hao/<svc>.env
"$SKILL/scripts/hao-secret.sh" write /etc/hao/nginx-hardening.env 'ADMIN_PASS=@password:20'
# 2. 渲染 htpasswd
"$SKILL/scripts/hao-secret.sh" render "$SKILL/templates/nginx-htpasswd.conf" \
    /etc/nginx/.htpasswd-<CONF_NAME> --from /etc/hao/nginx-hardening.env --mode 0640
# 3. 属组改成 nginx worker 实际的用户 —— **现场读回来，不要写死 nginx**
NGINX_USER="$(nginx -T 2>/dev/null | awk '$1 == "user" { gsub(/;/, "", $2); print $2; exit }')"
chgrp "${NGINX_USER:?读不到 nginx worker 用户，停下来手工确认}" /etc/nginx/.htpasswd-<CONF_NAME>
```

两个坑都在模板头部写了，这里只说后果：

- **不要 `sed -i '/^#/d'`**。之前这一步写在流程里，理由是"htpasswd 不能有
  注释"——是错的（`ngx_http_auth_basic_module` 会跳过 `#` 行，实测带注释头的
  htpasswd 认证完全正常）。删掉注释等于删掉 `# Managed by HAO` 头，
  `hao-guard.sh managed-file` 立刻变 `foreign`，以后没人能合法地轮换这个口令。
- **属组不能写死 `nginx`**。发行版 nginx 的 worker 是 `www-data`，写死要么
  `chgrp: invalid group`，要么设成 worker 不在的组——后者更坏：文件停在
  0640 root:nginx，每个后台请求都是 `[crit] Permission denied` + 500，
  而流程已经报告成功了。

然后把 `templates/nginx-admin-gateway.conf` 渲染（`@@ADMIN_PATH@@`、
`@@UPSTREAM@@`、`@@CONF_NAME@@`，token 含义见模板头）整段粘贴进该站点的内容
块，`nginx -t` 通过后 reload。这是在改站点的 managed 文件，重跑该站点的
record（同第 3 节）。

私密路径**不要用 `/admin`**——路径本身视同口令的一半，让用户起一个
扫不到的名字；要记进 DEPLOY-INTENT.md 与否，由用户拍板（那份文件 0644
且用户会带走）。

## 5. 验证（真实证据，nginx -t 通过不算数）

**必须探 443，不能探 `http://127.0.0.1/`。** 标准 HAO 的 TLS 站点里，80 端口
只有 ACME 片段加一条 `return 301`——内容块（连同 scanner-blocks 的拦截和安全
响应头）根本不在那个 server 里。对着 80 探，下面每一条都会拿到 301，看起来像
"加固没生效"，而配置其实是对的。`--resolve` 让 curl 连本机但按域名走 SNI 和
`server_name`；`-k` 是因为自签或链不全时不该在这一步卡住。

```bash
D="$DOMAIN"                       # 站点域名
C=(curl -sk --resolve "$D:443:127.0.0.1")

# 扫站路径 → 403
"${C[@]}" -o /dev/null -w '%{http_code} .env\n'        "https://$D/.env"
# 恶意 UA → 403
"${C[@]}" -A sqlmap -o /dev/null -w '%{http_code} bad-ua\n' "https://$D/"
# TRACE → 405
"${C[@]}" -X TRACE -o /dev/null -w '%{http_code} TRACE\n'   "https://$D/"
# 正常页面 → 200
"${C[@]}" -o /dev/null -w '%{http_code} /\n'           "https://$D/"
# 安全响应头真的在
"${C[@]}" -I "https://$D/" | grep -i x-content-type-options
```

ACME 探测是**唯一**要走 80 的一条——它验的就是 80 上那个 `^~` 前缀 location
能不能在 scanner-blocks 的点文件正则之前接走 challenge：

```bash
# → 404（**不能是 403**，否则下次续期失败）
curl -s -o /dev/null -w '%{http_code} acme\n' -H "Host: $DOMAIN" \
    http://127.0.0.1/.well-known/acme-challenge/probe
```

403 就停下来修——带着"下季度证书续期会莫名其妙失败"的状态收尾是不可接受的。

403 落在该站点自己的 access_log 里（那一行同时是 fail2ban 的口粮）：

```bash
tail -n 5 "/var/log/nginx/<CONF_NAME>.access.log"    # CONF_NAME = 站点内容块的名字
```

限流不要用本机 curl 轰（127.0.0.1 不触发 realip，还把日志刷脏）。真实 IP
还原的证据：站点在 CF 后面时，让用户浏览器打开一次站点，tail access.log，
`$remote_addr` 应是用户的真实出口 IP 而不是 `104.x/172.x` 这些 CF 网段。
想同时看清"这个请求是否绕过 CF 直连"，在临时 `log_format` 里加
`$realip_remote_addr`（realip 生效时它就是连接对端：CF 回源时是 CF 边缘 IP，
直连时是对方自己）。

## 6. 记录状态并交接

```bash
"$SKILL/scripts/hao-state.sh" record nginx-hardening installed \
    managed:/etc/nginx/conf.d/00-hao-hardening.conf \
    managed:/etc/nginx/snippets/scanner-blocks.conf \
    managed:/etc/nginx/snippets/security-headers.conf
"$SKILL/scripts/hao-state.sh" intent nginx-hardening behind_cloudflare=yes admin_gateway=no
"$SKILL/scripts/hao-state.sh" handoff
```

上了第 4 节网关的话，**两个**凭据资源都要加进 record，一个都不能漏：

```bash
"$SKILL/scripts/hao-state.sh" record nginx-hardening installed \
    managed:/etc/nginx/conf.d/00-hao-hardening.conf \
    managed:/etc/nginx/snippets/scanner-blocks.conf \
    managed:/etc/nginx/snippets/security-headers.conf \
    secret:/etc/hao/nginx-hardening.env \
    secret:/etc/nginx/.htpasswd-<CONF_NAME>
"$SKILL/scripts/hao-state.sh" intent nginx-hardening behind_cloudflare=yes admin_gateway=yes
```

`hao-state.sh credentials` 和 HANDOFF.md 的凭据清单**只枚举 `secret:` 类资源**。
漏记 `/etc/hao/nginx-hardening.env` 的后果是：机器上有一个活着的后台口令，
而状态里没有任何东西指向它——下一个 agent 找不到，卸载流程也不会清它。

网关 location 所在的那个站点也要重跑 record（同第 3 节，清单从
`/var/lib/hao/services/site-<ID>.resources` 读回来）。

## 7. 不要顺手做的事

- **不要开"源站只允许 CF 回源"**（防火墙只放行 CF 网段）。certbot 的
  HTTP-01 验证服务器是直连 80 的，开了下次续期就死。要开，先把所有证书
  迁到 DNS-01——那是一次需要用户确认的独立变更。
- 不要往 `ignoreip` 加用户自己的 IP（本模块的 jail 没这条，但 fail2ban-nginx
  的有——见那边）。
- 不要为了放行某个爬虫/某条路径改共享文件的整体逻辑，按模板注释的方式
  收窄那一条，并如实告诉用户改了什么。
- CF 边缘规则让用户自己配（没有凭据，不要代劳），把附录的表达式给他。

## 8. 附录：Cloudflare 边缘规则（免费版够用）

源站三层只能拦"已经打到机器"的流量；经 CF 代理的攻击更该在边缘拦。把下面
几条给用户（Security → WAF → Custom rules，表达式用 Edit expression 粘贴）：

1. **Block 扫站路径**：`http.request.uri.path` contains `/wp-` / `.php` /
   `.env` / `/.git` / `phpmyadmin` / `adminer` / `/vendor/` / `/actuator`。
2. **Block 恶意 UA**：`http.user_agent` contains `sqlmap` / `nikto` /
   `masscan` / `zgrab` / `wpscan`（与 00-hao-hardening.conf 的 bad_ua 表一致）。
3. **Managed Challenge 可疑爬虫**：`cf.threat_score gt 10` 或
   Bytespider——质询页真浏览器能过、脚本过不了，比直接 Block 少误伤 SEO
   （Googlebot/Bingbot 在 CF 的已验证 bot 列表里，自动豁免）。

挨条和源站 scanner-blocks 的清单对齐，两边保持一致。Cloudflare 的 IP 段
（https://www.cloudflare.com/ips/）变化时，`00-hao-hardening.conf` 里的
`set_real_ip_from` 也要跟着更新——模板头部写着这条维护义务。
