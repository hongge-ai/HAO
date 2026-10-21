#!/usr/bin/env bash
set -euo pipefail

# skill 结构完整性测试
#
# 散文替代脚本之后，shellcheck 管不到内容对不对。这份测试守住能自动守的部分：
# 引用的文件真的存在、frontmatter 合法、模板占位符自洽、插件清单能被解析。
# 悬空的 references/xxx.md 链接会让 skill 静默退化，这类问题必须挡在 CI。

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_DIR="$ROOT_DIR/skills/hao-deploy"
SKILL_MD="$SKILL_DIR/SKILL.md"

fail=0
note() { echo "ok   $1"; }
bad()  { echo "FAIL $1" >&2; fail=1; }

[ -f "$SKILL_MD" ] || { echo "缺少 $SKILL_MD" >&2; exit 1; }

# ---------- frontmatter ----------
python3 - "$SKILL_MD" <<'PY' || fail=1
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
if not t.startswith("---\n"):
    raise SystemExit("FAIL frontmatter 必须从文件第一行开始，否则整个文件被当作正文")
end = t.find("\n---\n", 3)
if end < 0:
    raise SystemExit("FAIL frontmatter 缺少结束分隔符")
fm = t[4:end]

fields, cur = {}, None
for line in fm.split("\n"):
    m = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
    if m:
        cur = m.group(1)
        fields[cur] = m.group(2)
    elif cur:
        fields[cur] += " " + line.strip()

if "description" not in fields or not fields["description"].strip():
    raise SystemExit("FAIL frontmatter 必须有非空 description，否则 Claude 不知道何时用它")

budget = len(fields.get("description", "")) + len(fields.get("when_to_use", ""))
if budget > 1536:
    raise SystemExit(f"FAIL description + when_to_use 合计 {budget} 字符，超过 1536 上限会被截断")

print(f"ok   frontmatter 合法（description + when_to_use = {budget}/1536 字符）")

# allowed-tools 里引用的脚本必须存在
# 形式是 Bash(${CLAUDE_SKILL_DIR}/scripts/x.sh:*) —— 末尾的 ":*" 是 Claude Code 的
# 前缀通配写法（不是 " *"），取路径时要把它去掉。
import os
at = fields.get("allowed-tools", "")
found_tools = 0
for m in re.finditer(r"\$\{CLAUDE_SKILL_DIR\}(/[^\s)]+)", at):
    rel = m.group(1).lstrip("/").rstrip(":*")
    found_tools += 1
    if not os.path.isfile(os.path.join(os.path.dirname(p), rel)):
        raise SystemExit(f"FAIL allowed-tools 引用了不存在的文件: {rel}")
if found_tools and ":*" not in at:
    raise SystemExit("FAIL allowed-tools 的通配要写成 Bash(cmd:*)，不是 Bash(cmd *)")
print("ok   allowed-tools 引用的脚本都存在且用 :* 通配")
PY

# ---------- SKILL.md 引用的 references/ 与 templates/ 都必须存在 ----------
missing=0
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [ ! -f "$SKILL_DIR/$ref" ]; then
        echo "FAIL SKILL.md 引用了不存在的文件: $ref" >&2
        missing=1
    fi
done < <(grep -ohE '(references|templates)/[A-Za-z0-9._-]+' "$SKILL_MD" | sort -u)
[ "$missing" -eq 0 ] && note "SKILL.md 引用的所有文件都存在" || fail=1

# ---------- 各 reference 引用的 templates/ 与 scripts/ 都必须存在 ----------
missing=0
while IFS= read -r doc; do
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        if [ ! -f "$SKILL_DIR/$ref" ]; then
            echo "FAIL $(basename "$doc") 引用了不存在的文件: $ref" >&2
            missing=1
        fi
    done < <(grep -ohE '(templates|references)/[A-Za-z0-9._-]+' "$doc" | sort -u)
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        if [ ! -f "$SKILL_DIR/$ref" ]; then
            echo "FAIL $(basename "$doc") 引用了不存在的脚本: $ref" >&2
            missing=1
        fi
    done < <(grep -ohE 'scripts/hao-[a-z]+\.sh' "$doc" | sort -u)
done < <(find "$SKILL_DIR/references" -name '*.md')
[ "$missing" -eq 0 ] && note "各 reference 引用的模板与脚本都存在" || fail=1

# ---------- 每个 reference 都应当被 SKILL.md 或其他 reference 指到 ----------
orphan=0
for doc in "$SKILL_DIR"/references/*.md; do
    name="references/$(basename "$doc")"
    if ! grep -qF "$name" "$SKILL_MD" \
        && ! grep -rqF "$name" "$SKILL_DIR"/references/*.md --exclude="$(basename "$doc")"; then
        echo "FAIL $name 没有被任何地方引用（agent 找不到它）" >&2
        orphan=1
    fi
done
[ "$orphan" -eq 0 ] && note "没有孤立的 reference" || fail=1

# ---------- 指向 docs/ 的引用必须存在 ----------
# references/ 会把用户指向 docs/ 下的指南，plugin.json 也引用过一份不存在的
# 发布文档。悬空的 docs/ 链接和悬空的 references/ 链接一样会让人扑空。
missing=0
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [ ! -f "$ROOT_DIR/$ref" ]; then
        echo "FAIL 引用了不存在的文档: $ref" >&2
        missing=1
    fi
done < <(grep -rhoE 'docs/[A-Za-z0-9._-]+\.md' \
    "$SKILL_DIR" "$ROOT_DIR/README.md" "$ROOT_DIR/CLAUDE.md" "$ROOT_DIR/SECURITY.md" \
    "$ROOT_DIR/.claude-plugin" 2>/dev/null | sort -u)
[ "$missing" -eq 0 ] && note "指向 docs/ 的引用都存在" || fail=1

# ---------- 四个脚本必须可执行且有帮助 ----------
for s in hao-guard hao-secret hao-state hao-remote; do
    script="$SKILL_DIR/scripts/$s.sh"
    if [ ! -x "$script" ]; then
        bad "$s.sh 不可执行"
        continue
    fi
    if "$script" --help 2>&1 | grep -q '用法'; then
        note "$s.sh --help 可用"
    else
        bad "$s.sh --help 无输出或缺用法说明"
    fi
done

# ---------- 模板里的 @@TOKEN@@ 必须是合法形式 ----------
badtoken=0
while IFS= read -r tok; do
    case "$tok" in
        @@[A-Z]*@@) ;;
        *) echo "FAIL 模板含非法占位符: $tok" >&2; badtoken=1 ;;
    esac
done < <(grep -ohE '@@[A-Za-z0-9_]+@@' "$SKILL_DIR"/templates/* 2>/dev/null | sort -u)
[ "$badtoken" -eq 0 ] && note "模板占位符格式合法" || fail=1

# ---------- 每个占位符都必须在该模板的注释里被说明 ----------
# 文档只说明一部分 token、剩下的靠猜，是个真实的故障源：漏掉的 @@SITE_ID@@ 会进
# `# HAO-SITE:` 归属头，之后 vhost-owner 把这个站点当成「别的站点」，
# 该站点再也无法更新自己。占位符的权威说明就放在模板自己的注释里，这条测试守住它。
# 只看注释行（不是"前 40 行"）—— 短模板的正文会落进那个窗口，
# 于是占位符靠"自己被用到"就算通过，那样这条检查等于没有。
undocumented=0
for tmpl in "$SKILL_DIR"/templates/*; do
    comments="$(grep -E '^[[:space:]]*(#|//)' "$tmpl" || true)"
    while IFS= read -r tok; do
        [ -n "$tok" ] || continue
        case "$comments" in
            *"$tok"*) ;;
            *)
                echo "FAIL $(basename "$tmpl") 用了 $tok 但注释里没说明它" >&2
                undocumented=1
                ;;
        esac
    done < <(grep -ohE '@@[A-Z][A-Z0-9_]*@@' "$tmpl" | sort -u)
done
[ "$undocumented" -eq 0 ] && note "每个模板的占位符都在注释里有说明" || fail=1

# ---------- 不得引用 certbot nginx 插件才会提供的文件 ----------
# 这两个文件由 python3-certbot-nginx 提供（`dpkg -S options-ssl-nginx.conf`），
# 而本 skill 只装 certbot 并用 certonly，所以它们在目标机上永远不存在。
# include 一个不存在的文件会让 nginx -t 在证书**签发成功之后**失败，
# 现象和原因看起来毫不相关 —— 这个 bug 真的发生过一次，别让它回来。
if grep -rn 'letsencrypt/options-ssl-nginx.conf\|letsencrypt/ssl-dhparams.pem' \
    "$SKILL_DIR/templates" 2>/dev/null | grep -v '^\S*:[0-9]*:\s*#' | grep -q .; then
    grep -rn 'letsencrypt/options-ssl-nginx.conf\|letsencrypt/ssl-dhparams.pem' \
        "$SKILL_DIR/templates" | grep -v '^\S*:[0-9]*:\s*#' >&2
    bad "模板引用了 python3-certbot-nginx 才提供的文件（本 skill 不装那个插件）"
else
    note "模板没有引用 certbot nginx 插件的文件"
fi

# ---------- 每个模块 reference 收尾都要 handoff ----------
# 漏掉 handoff 的模块不会出现在 HANDOFF.md 的更新里，下一个 agent 读到的是旧状态。
missing=0
for doc in "$SKILL_DIR"/references/*.md; do
    case "$(basename "$doc")" in
        handoff.md|safety.md|uninstall.md) continue ;;   # 跨模块文档，不是安装过程
    esac
    grep -q 'hao-state.sh" handoff\|hao-state.sh handoff' "$doc" \
        || { echo "FAIL $(basename "$doc") 收尾没有 hao-state.sh handoff" >&2; missing=1; }
done
[ "$missing" -eq 0 ] && note "每个模块过程都以 handoff 收尾" || fail=1

# ---------- reference 的代码块里不得用会和环境变量撞名的裸变量 ----------
# $USER / $GROUP / $HOME_DIR 在任何 root/sudo shell 里本来就有值（USER=root），
# 用它们装「目标用户」会让 runuser -u "$USER" 静默变成 root，且退出码为 0。
# 统一用 TARGET_USER / TARGET_GROUP / TARGET_HOME（模板里的 token 也是这三个）。
# 只检查 ```bash 代码块里的行 —— 正文里解释这个坑本身是应该的。
python3 - "$SKILL_DIR/references" <<'PY' || fail=1
import pathlib, re, sys

root = pathlib.Path(sys.argv[1])
bad = []
for doc in sorted(root.glob("*.md")):
    in_code = False
    for n, line in enumerate(doc.read_text(encoding="utf-8").splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_code = not in_code
            continue
        if not in_code:
            continue
        if not re.search(r"\$\{?(USER|GROUP|HOME_DIR)\}?\b", line):
            continue
        if re.search(r"SUDO_USER|TARGET_USER|TARGET_GROUP|TARGET_HOME|CC_USER|"
                     r"USER_|echo \$USER|USER=root", line):
            continue
        if line.lstrip().startswith("#"):     # 代码块里的注释在讲这个坑本身
            continue
        bad.append(f"{doc.name}:{n}: {line.strip()}")

if bad:
    for b in bad:
        print("FAIL 代码块里用了会和环境变量撞名的变量（改用 TARGET_*）: " + b, file=sys.stderr)
    raise SystemExit(1)
print("ok   reference 的代码块里没有 $USER/$GROUP/$HOME_DIR 这类撞名变量")
PY

# ---------- HAO 写的配置模板必须带 Managed by HAO 头（供归属判断） ----------
missing=0
for tmpl in "$SKILL_DIR"/templates/*; do
    case "$(basename "$tmpl")" in
        docker-daemon-logrotate.json) continue ;;   # JSON 不能带注释
    esac
    if ! head -n 12 "$tmpl" | grep -q 'Managed by HAO'; then
        echo "FAIL 模板缺少 'Managed by HAO' 头（hao-guard managed-file 将无法识别）: $(basename "$tmpl")" >&2
        missing=1
    fi
done
[ "$missing" -eq 0 ] && note "配置模板都带归属标记头" || fail=1

# ---------- 更新脚本模板不能以 .sh 结尾（会被 CI 的 shellcheck 误扫） ----------
if find "$SKILL_DIR/templates" -name '*.sh' | grep -q .; then
    bad "templates/ 下不应有 *.sh（含占位符会导致 shellcheck 失败），请用 .sh.tmpl"
else
    note "模板脚本命名不会被 shellcheck 误扫"
fi

# ---------- 插件清单 ----------
for manifest in "$ROOT_DIR/.claude-plugin/plugin.json" "$ROOT_DIR/.claude-plugin/marketplace.json"; do
    if [ ! -f "$manifest" ]; then
        bad "缺少 $(basename "$manifest")"
        continue
    fi
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$manifest" 2>/dev/null; then
        note "$(basename "$manifest") 是合法 JSON"
    else
        bad "$(basename "$manifest") 不是合法 JSON"
    fi
done

python3 - "$ROOT_DIR/.claude-plugin/marketplace.json" "$ROOT_DIR" <<'PY' || fail=1
import json, os, sys
m = json.load(open(sys.argv[1]))
root = sys.argv[2]
assert m.get("name"), "marketplace 缺 name"
assert m.get("owner"), "marketplace 缺 owner"
plugins = m.get("plugins") or []
assert plugins, "marketplace 没有 plugins 条目"
for p in plugins:
    assert p.get("name"), "plugin 条目缺 name"
    assert p.get("source"), "plugin 条目缺 source"
# 默认扫描位置必须真的有 skill
assert os.path.isfile(os.path.join(root, "skills", "hao-deploy", "SKILL.md")), \
    "skills/hao-deploy/SKILL.md 不在插件默认扫描位置"
print("ok   marketplace 条目与 skill 默认扫描位置一致")
PY

# ---------- 旧 CLI 不应再被引用 ----------
stale=0
while IFS= read -r hit; do
    echo "FAIL 仍有对已删除旧 CLI 的引用: $hit" >&2
    stale=1
done < <(grep -rnE 'hao-run\.sh|install-skill\.sh|references/services\.md|\./hao (plan|preflight|apply|status|doctor|inventory)' \
    "$SKILL_DIR" "$ROOT_DIR/README.md" "$ROOT_DIR/CLAUDE.md" 2>/dev/null || true)
[ "$stale" -eq 0 ] && note "没有残留的旧 CLI 引用" || fail=1

[ "$fail" -eq 0 ] || { echo "skill 结构测试失败" >&2; exit 1; }
echo "skill 结构测试通过"
