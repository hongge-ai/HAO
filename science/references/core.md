# core —— `sing-box` 通用底座（二进制、`conf.d` 服务与防污染路由基座）

本模块只装底座，不监听任何业务端口。后续无论部署 `reality`、`httpsproxy` 还是 `landing` 链式落地，都共用这一个 `sing-box` 进程与 `/etc/sing-box/conf.d/` 目录。

## 为什么要这样设计底座（三个踩出来的教训）

1. **为什么直接下官方静态压缩包校验 SHA256，不用上游一键脚本？**
   - 上游 `install.sh` 默认拉取稳定分支（`< 1.15` 的 `http` 入站尚不支持 `HTTP/2` 正向代理），且在部分精简版 Debian/Ubuntu 小内存机器上调用 `dpkg -i` 偶发段错误（Segfault）。
   - `sing-box` 跨大版本偶尔会废弃旧配置字段。**锁死经过真机验证的版本号 + SHA256 校验和**，可以保证任何时候在新机器上跑出来的行为 100% 一致。
2. **为什么必须在底座内置 `1.1.1.1` + `ipv4_only` 解析？**
   - **真实事故：** 部分海外 VPS 商家的默认系统 DNS（或系统镜像残留的 `/etc/hosts`）会把 `www.gstatic.com`、`fonts.googleapis.com` 解析到 `203.208.x.x`（Google 北京失效 IP）或不通的 IPv6 地址。由于海外绝大部分网页都引用了这两个域名的 JS/字体，一旦走宿主机默认解析，打开任何网页都会死等几十秒超时。
   - 在 `00-base.json` 里由 `sing-box` 直接向 `1.1.1.1` 发起纯 IPv4 解析，能彻底免疫宿主机 DNS 与 IPv6 故障。
3. **为什么第一条路由规则必须拒绝 `ip_is_private`？**
   - 公网代理一旦放行私有地址，任何拿到代理口令的人都可以把这台 VPS 当跳板，去访问服务器本机只监听 `127.0.0.1` 的数据库、面板或内部服务（这些内部服务往往因为“只监听回环”而未设密码）。
   - `sing-box` 按文件名字典序合并数组，`00-base.json` 保证私有地址拦截规则永远排在第 1 位（无需额外下载 `geoip.dat`）。

---

## 1. 只读检查

```bash
uname -m                                        # 确认架构: x86_64 或 aarch64
command -v sing-box && sing-box version || true
systemctl status sing-box --no-pager 2>/dev/null || true
systemctl status xray --no-pager 2>/dev/null || true
ls -la /etc/sing-box/conf.d/ 2>/dev/null || true

# 顺手检查宿主机 /etc/hosts 是否有历史残留的 Google 203.208.x.x 污染
grep -nE 'google|gstatic|googleapis' /etc/hosts || echo "/etc/hosts 干净"
```

停止与确认条件：
- 若正在使用 Xray，先走 [迁移与回滚](migration.md)。完成只读盘点并取得用户明确同意后再改动目标主机。
- 若机器上已有其他方式安装的 `sing-box.service` 正在跑业务（如 `/etc/sing-box/config.json` 单文件模式），**不要直接覆盖**——先向用户确认是要保留原配置迁移进 `conf.d/`，还是全新部署。
- 若 `/etc/hosts` 里查出了指向 `203.208.x.x` 的残留行，提醒用户确认后清理掉，避免影响主机上的其他程序。

---

## 2. 安装步骤

### 2.1 下载固定版本二进制并校验 SHA256

当前经过验证的版本为 `v1.15.0-alpha.13`（首个完整重写 `http` 入站支持 `HTTP/2` 正向代理的版本；待 `1.15.0` 正式版发布后可同步更新下方版本号与官方 Release 页对应的 SHA256）：

```bash
(
set -euo pipefail
SB_VERSION="1.15.0-alpha.13"

case "$(uname -m)" in
    x86_64|amd64)
        SB_ARCH="amd64"
        SB_SHA256="bfc39f643a5ecc1b702c5723ff662e61dde813f12b3af0d0cfce4f629ff74047"
        ;;
    aarch64|arm64)
        SB_ARCH="arm64"
        SB_SHA256="6347b1405ec7e1b02fbed77f3b9ae12ba494cc3eb9f47c4adb6877c807a64bf5"
        ;;
    *)
        echo "不支持的 CPU 架构: $(uname -m)" >&2
        exit 1
        ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TMP_DIR"' EXIT
TARBALL="sing-box-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"
URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${TARBALL}"

curl -fL --connect-timeout 20 --max-time 300 -o "${TMP_DIR}/${TARBALL}" "$URL"
echo "${SB_SHA256}  ${TMP_DIR}/${TARBALL}" | sha256sum -c -

tar -xzf "${TMP_DIR}/${TARBALL}" -C "$TMP_DIR"
binary="${TMP_DIR}/sing-box-${SB_VERSION}-linux-${SB_ARCH}/sing-box"
"$binary" version
test ! -e /usr/local/bin/sing-box
install -m 0755 "$binary" /usr/local/bin/sing-box
)
```

若所需版本已在 `/usr/local/bin/sing-box`，核对版本及来源后可直接继续。已有其他版本时先确认升级方案。

### 2.2 创建配置目录、写入 `00-base.json` 与 `systemd` 单元

从仓库根目录以 root 执行。底座安装只写入配置与单元文件，入站配置验收时再启动服务。

```bash
(
set -euo pipefail
test ! -e /etc/sing-box/conf.d/00-base.json
test ! -e /etc/systemd/system/sing-box.service
# conf.d 与 clients 设为 0700：后续入站配置与客户端连接说明含口令/私钥，禁止同机非 root 用户读取
install -d -m 0755 /etc/sing-box /var/lib/sing-box
install -d -m 0700 /etc/sing-box/conf.d /etc/sing-box/clients
candidate="$(mktemp -d /etc/sing-box/.base.XXXXXX)"
trap 'rm -rf -- "$candidate"' EXIT
cp -a /etc/sing-box/conf.d/. "$candidate/"
install -m 0644 science/templates/00-base.json "$candidate/00-base.json"
/usr/local/bin/sing-box check -D /var/lib/sing-box -C "$candidate"
systemd-analyze verify "$PWD/science/templates/sing-box.service"
install -m 0644 "$candidate/00-base.json" /etc/sing-box/conf.d/00-base.json
install -m 0644 science/templates/sing-box.service /etc/systemd/system/sing-box.service
systemctl daemon-reload
)
```

---

## 3. 验证底座

```bash
/usr/local/bin/sing-box check -D /var/lib/sing-box -C /etc/sing-box/conf.d
```

返回码为 `0` 且无报错，即说明底座就绪，接下来可以按需继续部署 [httpsproxy.md](httpsproxy.md) 或 [reality.md](reality.md)。

### 修改配置时先暂存，再应用

在同一个 root Bash 会话中定义下方两个函数，再执行各章节的配置块。每个配置块都在子 shell 中持有同一把锁，在权限为 `0700` 的暂存目录里修改完整配置和客户端文件。校验通过后才替换现有目录。若发布或重启命令报错，恢复旧文件及原来的运行状态。端到端验证仍按各章节执行。

```bash
prepare_sing_box() {
    umask 077
    exec 9>/run/lock/sing-box-config.lock
    flock -n 9
    STAGE="$(mktemp -d /etc/sing-box/.stage.XXXXXX)"
    trap '[[ -e "$STAGE/.keep" ]] || rm -rf -- "$STAGE"' EXIT
    cp -a /etc/sing-box/{conf.d,clients} "$STAGE/"
}

apply_sing_box() (
    set -euo pipefail
    /usr/local/bin/sing-box check -D /var/lib/sing-box -C "$STAGE/conf.d" || exit "$?"
    local live=/etc/sing-box dir was_active=0
    if systemctl is-active --quiet sing-box; then
        was_active=1
    fi
    mkdir "$STAGE/previous" || exit "$?"
    touch "$STAGE/.keep" || exit "$?"
    rollback_sing_box() {
        local status=$? failed=0 dir
        if (( status == 0 )); then
            rm -f -- "$STAGE/.keep"
            return
        fi
        for dir in conf.d clients; do
            if [[ -d "$STAGE/previous/$dir" ]]; then
                if [[ -d "$live/$dir" ]]; then
                    mv -T -- "$live/$dir" "$STAGE/$dir" || failed=1
                fi
                mv -T -- "$STAGE/previous/$dir" "$live/$dir" || failed=1
            fi
        done
        if (( was_active )); then
            systemctl restart sing-box || failed=1
        else
            systemctl stop sing-box || failed=1
        fi
        if (( failed )); then
            printf '恢复未完成，保留暂存及备份：%s\n' "$STAGE" >&2
        else
            rm -f -- "$STAGE/.keep"
        fi
        exit "$status"
    }
    trap rollback_sing_box EXIT

    for dir in conf.d clients; do
        mv -T -- "$live/$dir" "$STAGE/previous/$dir" || exit "$?"
        mv -T -- "$STAGE/$dir" "$live/$dir" || exit "$?"
    done
    systemctl restart sing-box || exit "$?"
    systemctl is-active --quiet sing-box
)
```

首次启用时，客户端验收通过后执行 `systemctl enable sing-box`，使服务随系统启动。

---

## 4. 彻底卸载底座

确认 `/etc/sing-box/conf.d/` 下已无需要的入站服务后：

```bash
systemctl disable --now sing-box 2>/dev/null || true
rm -f /etc/systemd/system/sing-box.service
systemctl daemon-reload
rm -f /usr/local/bin/sing-box
rm -rf /etc/sing-box /var/lib/sing-box
```
