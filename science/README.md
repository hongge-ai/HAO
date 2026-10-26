# 出网工具

> 不在主仓库的 skill 流程里，也不进任何模块表。要用就自己进这个目录跑 `install.sh`。

两个工具，可以只装一个，也可以都装（共用一个 xray 进程，配置文件各自独立）。
都装是合理的：它们的强项互补，一条被封另一条通常还活着。

| | `reality` | `proxy` |
|---|---|---|
| 客户端里怎么填 | 导入 vless:// 链接 | `https 域名 端口 用户名 口令` |
| 需要域名 | 不需要 | **需要**（要签证书） |
| 需要证书 | 不需要 | 需要（自动 certbot 签） |
| 抗主动探测 | 很强（伪装成真站点） | 一般（就是个 TLS 端口） |
| 兼容性 | 只有专门的客户端能用 | 任何能填 HTTPS 代理的软件 |
| 转 UDP | 能 | **不能，只转 TCP** |

## 快速开始

```bash
sudo ./install.sh status                 # 先看现在是什么状态（只读，随便跑）

sudo ./install.sh reality                # 装 Reality，默认 443
sudo ./install.sh proxy --domain proxy.example.com   # 装 HTTPS 代理，默认 8443
sudo ./install.sh bbr                    # 顺手打开 BBR
```

前置：root、Debian 12/13 或 Ubuntu 22.04/24.04/26.04、一台在墙外的机器。
`proxy` 还需要一个已经解析到这台机器的域名。

每个子命令都有自己的 `-h`：

```bash
./install.sh proxy -h
```

**重跑是安全的。** 默认复用已有的密钥、UUID、口令和证书，不会让已经在用的客户端掉线。
要换凭据得显式说：`--rotate-keys`（Reality）或 `--rotate-password`（代理）。

## 工具一：`reality`

VLESS + XTLS-Vision + Reality。借用一个真实站点（默认 `www.bing.com`）的
TLS 握手特征做伪装：被主动探测时把流量原样转给那个站点，探测者拿到的是对方的真实证书，
看不出这里有代理。所以不需要自己的域名，也不需要证书。

```bash
sudo ./install.sh reality --port 443 --sni www.bing.com
```

**为什么默认是 bing.com**：2026-10 实测能完成 TLS 1.3 Reality 握手和真实代理请求。Reality 是把 `dest` 的握手字节原样转发，选目标时按这个顺序看：
**真实 Reality 握手通过 → 证书链短于等于 3 级 → TLS 1.3 可协商 → 服务器能稳定连上
→ 知名大厂站点**。不要只看知名度，也不要选 Cloudflare 节点（`www.cloudflare.com`、
`www.speedtest.net` 之类，那段 IP 被大量代理滥用，已是重点监控对象）。

客户端参数（含 UUID、公钥、shortId 和 vless:// 分享链接）写在
`/etc/hao/xray-reality.client.txt`，权限 0600，自己 `sudo cat` 去看。
客户端用 v2rayN / v2rayNG / Shadowrocket / sing-box / Mihomo，安全类型选 `reality`。

`--sni` 换别的站点时，那个站点必须**从这台服务器能连上**，而且它自己得支持
TLS 1.3（Reality 要复现的就是对方的 TLS 1.3 握手）。脚本只验证可达性这一项，
TLS 1.3 要你自己确认：`openssl s_client -tls1_3 -connect <站点>:443 </dev/null`。
连不上的伪装目标等于没有伪装。可达且支持 TLS 1.3 也不保证兼容：`www.microsoft.com`
的 Certificate 记录可能超过 Reality 的 8192 字节预读上限，导致握手失败。换目标后
必须用真实客户端发起代理请求，不能只看配置检查或伪装站点的证书。

## 工具二：`proxy`（就是「https 域名 端口 用户名 口令」那种）

一个 HTTP 正向代理入站，外面包一层 TLS，认证用 HTTP Basic。别人给你代理时报的
那串参数就是这个。

```bash
sudo ./install.sh proxy --domain proxy.example.com --port 8443 --user example-usr
```

口令默认自动生成 32 位随机串。要自带口令：

```bash
sudo ./install.sh proxy --domain proxy.example.com --password-file /root/pw.txt
sudo ./install.sh proxy --domain proxy.example.com --password-env MY_PW
```

**没有 `--password` 这个选项，这是故意的。** 命令行参数对同机任何用户可见
（`/proc/<pid>/cmdline`），口令走那里等于公开。

完整参数在 `/etc/hao/xray-httpsproxy.client.txt`（0600）。里面有一行就是
`https <域名> <端口> <用户名> <口令>` 的形式（在 `[一行形式]` 那一段下），
可以直接抄给客户端。

### 哪些软件能直接用，哪些不能

这一点最容易搞错：**「到代理本身走 TLS」不是所有软件都支持。**

- **能**：Shadowrocket、Clash / Mihomo（`type: http` + `tls: true`）、Surge、
  Quantumult X、sing-box、`curl --proxy https://...`（需要 7.52+）、
  Chrome 的 `--proxy-server=https://域名:端口`
- **不能**：`git`、`pip`、`apt`，以及 Windows / macOS 系统代理设置里的「HTTP 代理」栏。
  它们只认**明文** HTTP 代理，填这个地址会直接失败。
  办法是本地跑 Clash / Mihomo，把这条代理当出口，它会在 `127.0.0.1` 上开一个
  明文 http 端口给这些工具用。

### 只转 TCP

HTTP 代理协议本身不支持 UDP。QUIC（部分视频站）、UDP 游戏、DNS over UDP 走不了这条，
会回落到 TCP 或直连。要全流量代理走 `reality`。

### 证书

用 certbot 签 Let's Encrypt（`certonly`，**不装** `python3-certbot-nginx` —— 那个插件会去改
Nginx 配置，和这套模板打架）。80 端口空着就用 `--standalone`；被 Nginx 占着就用
`--webroot -w /var/www/html`，签之前会先自己放一个探测文件确认那个路径真的能从公网取到
（失败的验证要算进 Let's Encrypt 的速率限制，不值得盲试）。

续期不需要你做任何事：`certbot.timer` 随包安装，另外装了一个
`/etc/letsencrypt/renewal-hooks/deploy/restart-xray.sh` 做兜底。

签不下来会降级成自签名，并明确告诉你这是自签名 —— 那种情况下客户端必须能勾
「跳过证书校验」，而很多代理客户端没有这个开关。用 `--selfsigned` 可以直接跳过真证书。

## 你自己要做的两件事

脚本不会代你改防火墙（把自己关在门外的风险比省下的事大），云服务商的安全组更不在这台机器上：

1. **云控制台的安全组 / 防火墙放行对应端口的 TCP**（默认 443 / 8443）。这是连不上时最常见的原因。
2. **DNS**（只有 `proxy` 需要）：一条 A 记录指向这台机器。
   用 Cloudflare 的话**必须是灰云（DNS only）** —— 橙云不代理这类端口。

机器上如果开着 ufw / firewalld，脚本会把该执行的命令打给你，但不会自己跑。

## 装完之后

```bash
sudo ./install.sh status          # 装了什么、在听哪些端口、凭据文件在哪
systemctl status xray
journalctl -u xray -f
sudo /usr/local/bin/xray run -test -confdir /usr/local/etc/xray/conf.d   # 相当于 nginx -t
```

**不要 `cat /usr/local/etc/xray/conf.d/*.json`** —— 那里面有私钥和口令。
要看客户端参数就看 `/etc/hao/*.client.txt`。

状态记进 `/var/lib/hao`（服务名 `xray-core` / `xray-reality` / `xray-httpsproxy` / `bbr`），
所以 `hao-state.sh drift` 能发现有人手工改了配置，交接文档里也查得到。
`/var/lib/hao/DEPLOY-INTENT.md` 存一份到自己的笔记里 —— 机器销毁后那是重建依据
（里面不含任何凭据）。

## 文件都在哪

| 什么 | 路径 |
|---|---|
| 二进制 | `/usr/local/bin/xray` |
| systemd 单元 | `/etc/systemd/system/xray.service`（用 `-confdir` 启动） |
| 共用配置 | `/usr/local/etc/xray/conf.d/00-base.json` |
| Reality 入站 | `/usr/local/etc/xray/conf.d/10-reality.json`（0600，含私钥） |
| 代理入站 | `/usr/local/etc/xray/conf.d/20-httpsproxy.json`（0600，含口令） |
| 凭据 | `/etc/hao/xray-*.env`（0600） |
| 客户端参数 | `/etc/hao/xray-*.client.txt`（0600） |
| geo 数据 | `/usr/local/share/xray/` |
| 日志 | `/var/log/xray/error.log`（access log 故意关掉了，见下） |

一个入站一个配置文件是刻意的：装代理不用重写 Reality 的配置，卸一个只需删一个文件，
`drift` 也能分别检查。

**access log 默认关闭。** 一台个人代理的访问日志就是「这个人访问过哪些网站」的清单，
留在盘上是纯粹的隐私负担，而且没人给它配轮转，早晚涨满磁盘。排查问题看 error log
和 `journalctl` 足够。

**私有地址被路由规则挡掉**（`geoip:private` → `block`）。不挡的话，拿到代理口令的人
可以用这台机器当跳板去打只监听 `127.0.0.1` 的本机服务 —— 那些服务往往因为
「只有本机能连」而根本没设密码。

## 卸载

```bash
sudo ./install.sh uninstall reality      # 只卸 Reality 入站
sudo ./install.sh uninstall proxy        # 只卸代理入站
sudo ./install.sh uninstall bbr
sudo ./install.sh uninstall core         # 卸 xray 本身（要求入站已全部卸掉）
sudo ./install.sh uninstall all
```

会先列出要删的文件再问你。**凭据文件删掉就找不回来了**，需要留的先自己导出。
证书一律不删（可能有别的服务在用同一张）；真要停续期用 certbot 自己的命令：
`certbot delete --cert-name <域名>`。

## 常见问题

- **客户端连不上，服务端一切正常** —— 九成是云安全组没放行那个端口。先查这个。
- **代理返回 407** —— 认证失败。用户名或口令不对；参数看
  `/etc/hao/xray-httpsproxy.client.txt`。
- **证书签不下来** —— DNS 是否指向本机（Cloudflare 要灰云）、80 端口能否从公网访问、
  域名是否被别的 nginx server 块抢走。
- **`curl: (35)` 或握手失败** —— 客户端类型选成了 HTTP 而不是 HTTPS；
  或者用的是自签名证书而客户端没勾「跳过证书校验」。
- **BBR 没生效** —— `sysctl -n net.ipv4.tcp_congestion_control` 看实际值，
  需要内核 >= 4.9。脚本会如实告诉你没生效，不会报成功。
- **`xray -test` 说 `open /var/log/xray/error.log: no such file`** —— 日志目录没建，
  `install.sh` 会建；手工跑的话 `install -d -m 0755 /var/log/xray`。

## 验收清单（改过配置或换过机器之后照着走一遍）

```bash
sudo /usr/local/bin/xray run -test -confdir /usr/local/etc/xray/conf.d   # 配置合法
systemctl is-active xray                                                # 服务活着
ss -tlnp | grep xray                                                    # 端口真的在听

# 代理端到端。口令放 0600 的 curl 配置文件里，既不进命令行参数也不进 shell 历史：
install -m 600 /dev/null /tmp/pc          # 先建好权限再写内容
printf 'proxy = "https://<域名>:<端口>"\nproxy-user = "<用户>:' > /tmp/pc
read -rs -p '口令（不回显）: ' PW && printf '%s"\n' "$PW" >> /tmp/pc && unset PW
curl -K /tmp/pc https://api.ipify.org; rm -f /tmp/pc    # 应该返回服务器的公网 IP

# Reality 的伪装是否成立：应该看到伪装目标（如 Bing）的真实证书
openssl s_client -connect <服务器IP>:443 -servername www.bing.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer
```

`install.sh` 自己也会跑前三项，并在装完代理后真的走一遍代理验证（用同样的
0600 配置文件方式）。它不会因为命令退出码是 0 就报成功。
