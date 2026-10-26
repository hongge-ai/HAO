#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

printf '== bash -n ==\n'
find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -name '*.sh' -print0 \
  | xargs -0 -n1 bash -n

if command -v shellcheck >/dev/null 2>&1; then
  printf '== shellcheck ==\n'
  find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -name '*.sh' -print0 \
    | xargs -0 shellcheck -x -S warning
elif [ "${HAO_ALLOW_MISSING_SHELLCHECK:-}" = "1" ]; then
  printf '== shellcheck skipped: not installed (HAO_ALLOW_MISSING_SHELLCHECK=1) ==\n' >&2
else
  printf 'ERROR: shellcheck 未安装，静态检查无法运行。\n' >&2
  printf '  安装: apt-get install -y shellcheck\n' >&2
  printf '  仅在确知无法安装时用 HAO_ALLOW_MISSING_SHELLCHECK=1 显式跳过。\n' >&2
  exit 1
fi

printf '== skill structure ==\n'
"$ROOT_DIR/tests/test-skill-structure.sh"

printf '== site 更新脚本（渲染后真的跑一遍）==\n'
"$ROOT_DIR/tests/test-site-update.sh"

printf '== nginx 配置（渲染后交给真的 nginx -t）==\n'
"$ROOT_DIR/tests/test-nginx-config.sh"

printf '== hao-guard ==\n'
"$ROOT_DIR/tests/test-guard.sh"

printf '== hao-secret ==\n'
"$ROOT_DIR/tests/test-secret.sh"

printf '== hao-state ==\n'
"$ROOT_DIR/tests/test-state.sh"

printf '== hao-remote ==\n'
"$ROOT_DIR/tests/test-remote.sh"

printf '== generic skill (runtime-neutral) ==\n'
"$ROOT_DIR/tests/test-generic-skills.sh"

printf '== hidden modules ==\n'
"$ROOT_DIR/tests/test-hidden-modules.sh"

printf '== science module (offline render + refusals) ==\n'
"$ROOT_DIR/tests/test-science.sh"

if command -v claude >/dev/null 2>&1; then
  printf '== plugin manifest validation ==\n'
  claude plugin validate "$ROOT_DIR" --strict
else
  printf '== plugin validate skipped: claude CLI not installed ==\n' >&2
fi

printf 'All tests passed.\n'
