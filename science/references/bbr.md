# bbr —— 内核 BBR 拥塞控制与网卡 `fq` 队列实效调优

跨洋高延迟链路（如美西 160ms+ RTT）打开 BBR 对单连接吞吐提升非常明显。

## 必知避坑：为什么很多机器“开了 BBR”却依然限速？

**真实事故：** 许多云镜像在 `/etc/sysctl.conf` 里预置了 `bbr` 和 `net.core.default_qdisc = fq`，`sysctl` 读出来也确实显示 `bbr` 与 `fq`；但用 `tc qdisc show` 一看，物理出口网卡（如 `ens7` / `eth0`）实际挂载的根队列依然是老旧的 **`pfifo_fast`**！

原因：`net.core.default_qdisc` 只决定**此后新初始化的队列**用什么算法，执行 `sysctl -p` **不会**自动替换活动网卡上已经挂着的旧根队列。缺失 `fq`（Fair Queueing 发包平滑调度）会让 BBR 在跨国链路上突发丢包，实测单流吞吐直接损失 30%～50%。

所以：本模块既写持久化配置，也显式对默认出口网卡执行 `tc qdisc replace ... root fq`，并以 `tc qdisc show` 的回读结果作为唯一验收标准。

---

## 1. 只读检查

```bash
# 当前拥塞控制算法与默认队列配置
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc

# 当前默认公网出口网卡及其【实际生效】的根队列
DEFAULT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
echo "默认出口网卡: ${DEFAULT_IF:-未识别}"
[ -n "${DEFAULT_IF:-}" ] && tc qdisc show dev "$DEFAULT_IF"

# 是否已有配置文件固化了 BBR
grep -rnE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr' \
    /etc/sysctl.conf /etc/sysctl.d/*.conf 2>/dev/null || echo "尚未持久化"
```

判断规则：
- 若拥塞控制已是 `bbr`、已有配置文件持久化、**且** `tc qdisc show dev "$DEFAULT_IF"` 显示 `qdisc fq` → 已完全就绪，无需改动。
- 若拥塞控制已是 `bbr`，但网卡显示的还是 `pfifo_fast` 或 `fq_codel` → 只需补写持久化（若缺失）并执行第 2 步的 `tc qdisc replace`。

---

## 2. 部署步骤

将 `templates/sysctl-bbr.conf` 写入 `/etc/sysctl.d/99-bbr-fq.conf` 并立即切换网卡根队列：

```bash
modprobe tcp_bbr 2>/dev/null || true

cat << 'EOF' > /etc/sysctl.d/99-bbr-fq.conf
# 目标路径: /etc/sysctl.d/99-bbr-fq.conf  (0644)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
chmod 0644 /etc/sysctl.d/99-bbr-fq.conf

sysctl --system >/dev/null

# 当场替换默认出口网卡的根队列为 fq（无需重启服务器立即生效）
DEFAULT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
if [ -n "${DEFAULT_IF:-}" ]; then
    tc qdisc replace dev "$DEFAULT_IF" root fq
fi
```

---

## 3. 真证据验收（两项都必须过）

```bash
DEFAULT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"

# 1. 期望输出: bbr
sysctl -n net.ipv4.tcp_congestion_control

# 2. 期望首行包含: qdisc fq ... root
tc qdisc show dev "$DEFAULT_IF" | head -n 1
```

如果内核版本低于 4.9（或 OpenVZ/LXC 容器共享宿主机内核）导致回读仍非 `bbr`，如实说明当前虚拟化架构不支持修改内核拥塞控制即可。

---

## 4. 卸载

```bash
rm -f /etc/sysctl.d/99-bbr-fq.conf
# 重启服务器后自动恢复发行版默认拥塞控制算法与队列
```
