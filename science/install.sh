#!/usr/bin/env bash
#
################################################################################
#
# 出网工具部署入口（一个工具一个子命令）
#
#   reality    VLESS + XTLS-Vision + Reality 入站。不要域名、不要证书，抗封锁最强
#   proxy      HTTPS 正向代理（用户名 + 口令）。客户端里填「https 域名 端口 用户 口令」
#   bbr        打开 BBR 拥塞控制（主机级调优，独立装卸）
#   status     当前装了什么、在听哪些端口、凭据文件在哪（只读）
#   uninstall  按目标卸载
#
# 设计约定（和仓库其余模块一致，理由见根目录 AGENTS.md）：
#   - 改系统之前先把要做的事讲清楚并取得确认；只读检查不需要确认
#   - 目标已存在且不是本工具写的 -> 停下来，绝不覆盖
#   - 幂等：重跑不换线上凭据、不重复下载、不重复写同样的文件
#   - 凭据只报路径，永不打印内容；用户自带口令走 --password-file / --password-env
#   - 状态一律经 hao-state.sh 写入，收尾 handoff，下一个 agent 才能接手
#
# 用法:
#   sudo ./install.sh <子命令> [选项]
#   ./install.sh -h
#
# 环境变量:
#   HAO_UNATTENDED=1      跳过交互确认（调用方自己负责已经取得用户确认）
#   HAO_SKILL_DIR=PATH    指定 skill 目录（默认取仓库里的 skills/hao-deploy）
#   HAO_XRAY_VERSION=vX   指定 xray 版本（默认用脚本里固定的版本，含校验和）
#
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/core.sh
. "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=lib/reality.sh
. "$SCRIPT_DIR/lib/reality.sh"
# shellcheck source=lib/httpsproxy.sh
. "$SCRIPT_DIR/lib/httpsproxy.sh"
# shellcheck source=lib/bbr.sh
. "$SCRIPT_DIR/lib/bbr.sh"
# shellcheck source=lib/manage.sh
. "$SCRIPT_DIR/lib/manage.sh"

usage() {
    cat >&2 <<'EOF'
用法: sudo ./install.sh <子命令> [选项]

子命令:
  reality      装 VLESS + Reality 入站（默认 443）
                 不需要域名和证书，抗主动探测最强，但只有专门的客户端能用
  proxy        装 HTTPS 正向代理（默认 8443），用户名 + 口令认证
                 客户端里填：https <域名> <端口> <用户名> <口令>
                 需要一个已解析到本机的域名（要签证书）
  bbr          打开 BBR 拥塞控制
  status       看当前状态（只读，随便跑）
  uninstall    卸载: uninstall <reality|proxy|bbr|core|all>

每个子命令都支持 -h 看自己的选项，例如:
  ./install.sh proxy -h

两种入站可以同时装（共用一个 xray 进程，配置各自独立），互为备份：
代理端口万一被封，Reality 那条通常还活着。

先看看这台机器现在是什么状态:
  sudo ./install.sh status
EOF
}

main() {
    local subcommand="${1:-}"
    [ "$#" -gt 0 ] && shift || true

    case "$subcommand" in
        reality)   cmd_reality "$@" ;;
        proxy)     cmd_proxy "$@" ;;
        bbr)       cmd_bbr "$@" ;;
        status)    cmd_status "$@" ;;
        uninstall) cmd_uninstall "$@" ;;
        -h|--help|help|"") usage ;;
        *) usage; die "不认识的子命令: $subcommand" ;;
    esac
}

main "$@"
