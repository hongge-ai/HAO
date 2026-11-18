#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=proxy.example.com \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >/dev/null 2>&1

python3 - "$ROOT/science" "$WORK" << 'PY'
import base64
import json
import re
import subprocess
import sys
import textwrap
from pathlib import Path

science, work = map(Path, sys.argv[1:])
templates = science / "templates"
placeholder = re.compile(r"@@([A-Z][A-Z0-9_]*)@@")
key = base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip("=")
uuid = "11111111-1111-4111-8111-111111111111"


def render(name, **values):
    source = (templates / name).read_text(encoding="utf-8")
    body = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("//"))
    config = json.loads(placeholder.sub(lambda match: str(values[match[1]]), body))
    return name.removesuffix(".tmpl"), config


base = render("00-base.json")
reality = render(
    "10-reality.json.tmpl", PORT=8443, DEST_SNI="example.com", UUID=uuid,
    PRIVATE_KEY=key, SHORT_ID="0011223344556677",
)
httpsproxy = render(
    "20-httpsproxy.json.tmpl", PORT=8444, DOMAIN="proxy.example.com",
    CERT_FULLCHAIN=work / "cert.pem", CERT_KEY=work / "key.pem",
    PROXY_USER="fixture", PROXY_PASSWORD="fixture-password",
)
landing = render(
    "30-landing.json.tmpl", LANDING_PORT=443, LANDING_SERVER="192.0.2.10",
    LANDING_UUID=uuid, LANDING_SNI="example.com", LANDING_PUBLIC_KEY=key,
    LANDING_SHORT_ID="0011223344556677", ISP_USER="px_isp",
)

assert base[1]["route"]["rules"][0] == {"ip_is_private": True, "action": "reject"}
assert httpsproxy[1]["inbounds"][0]["version"] == [1, 2]
assert httpsproxy[1]["inbounds"][0]["tls"]["alpn"] == ["h2", "http/1.1"]
for name, modules in {
    "base": (),
    "reality": (reality,),
    "httpsproxy": (httpsproxy,),
    "reality-landing": (reality, landing),
    "httpsproxy-landing": (httpsproxy, landing),
    "full": (reality, httpsproxy, landing),
}.items():
    conf = work / name
    conf.mkdir()
    for filename, data in (base, *modules):
        (conf / filename).write_text(json.dumps(data), encoding="utf-8")

for doc in sorted((science / "references").glob("*.md")):
    blocks = re.findall(r"^[ \t]*```bash[ \t]*\n(.*?)^[ \t]*```[ \t]*$", doc.read_text(encoding="utf-8"), re.M | re.S)
    for index, block in enumerate(blocks, 1):
        # Markdown list examples are indented, including any heredoc terminator.
        try:
            subprocess.run(["bash", "-n"], input=textwrap.dedent(block), text=True, check=True)
        except subprocess.CalledProcessError:
            raise SystemExit(f"{doc.name}: Bash 示例 {index} 语法检查失败") from None
PY

bash -n "$ROOT/science/templates/certbot-deploy-hook-sing-box.sh.tmpl"
node --check "$ROOT/science/scripts/bench-h2.mjs"

if command -v sing-box >/dev/null 2>&1; then
    mkdir "$WORK/data"
    cp "$ROOT/science/templates/00-base.json" "$WORK/base/00-base.json"
    for config in "$WORK"/{base,reality,httpsproxy,reality-landing,httpsproxy-landing,full}; do
        sing-box check -D "$WORK/data" -C "$config"
    done
    sing-box merge "$WORK/merged.json" -D "$WORK/data" -C "$WORK/full"
    python3 - "$WORK/merged.json" << 'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as merged:
    config = json.load(merged)
assert [inbound["tag"] for inbound in config["inbounds"]] == ["reality-in", "httpsproxy-in"]
assert [outbound["tag"] for outbound in config["outbounds"]] == ["direct", "landing-out"]
assert config["route"]["rules"][0] == {"ip_is_private": True, "action": "reject"}
assert config["route"]["rules"][1]["outbound"] == "landing-out"
PY
elif [[ "${HAO_REQUIRE_SING_BOX:-}" = 1 ]]; then
    printf 'CI 需要 sing-box 检查合并后的配置。\n' >&2
    exit 1
else
    printf '跳过 sing-box 配置检查，本机未安装 sing-box。\n' >&2
fi

printf 'science 工具书、模板和脚本检查通过。\n'
