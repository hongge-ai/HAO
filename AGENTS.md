# AGENTS.md

This file provides guidance to AI coding agents working with code in this repository.

原名 `CLAUDE.md`。改名的原因：`claude plugin validate --strict` 会把仓库根
（marketplace 里 `source: "./"` 指向的那一层）当成插件目录，见到根上的
`CLAUDE.md` 就报「at the plugin root is not loaded as project context」。
`AGENTS.md` 是同类约定文件名，Claude Code 与多数 runtime 都会默认加载。

## What this is

HAO (HongAgentOps) is an **AI agent skill** for deploying websites and dev/ops tooling
on Debian/Ubuntu servers, aimed at users who don't know operations. It is not a CLI
toolkit: the deployment procedures live as prose in `skills/hao-deploy/references/`
and are executed by the agent itself. Docs and comments are largely in Chinese.

The repository doubles as a Claude Code **plugin** (`.claude-plugin/`), so the whole
repo is the distribution unit.

## Commands

```bash
# Full suite: bash -n, shellcheck, structure test, behavior tests, plugin validation
./tests/run.sh                      # requires shellcheck (apt-get install -y shellcheck)

# Individual suites
./tests/test-skill-structure.sh     # frontmatter, dangling refs, template hygiene
./tests/test-guard.sh               # hao-guard.sh behavior (read-only checks)
./tests/test-secret.sh              # credential generation, reuse, render
./tests/test-state.sh               # state records, drift, handoff, marker blocks

# Lint one file (CI uses these exact flags)
shellcheck -x -S warning path/to/script.sh

# Plugin
claude plugin validate . --strict
claude --plugin-dir . -p "..."      # load the skill locally to try it
```

There is no build step and no installer. The skill mutates a host only when an agent
follows a procedure in `references/` and the user has confirmed.

## Architecture

- **`skills/hao-deploy/SKILL.md`** is the entry point: intent→module mapping, the
  six-step workflow (ask → read-only checks → explain and confirm → execute per
  reference → verify with real evidence → record state and hand off), and the hard rules.
- **`references/<module>.md`** — one procedure per module ("how to check, how to
  install"), carrying the non-obvious operational knowledge: exact commands, ordering
  constraints, refusal conditions, and the reasons behind them. This is where the old
  installer scripts went. Cross-module docs: `handoff.md` (state format and the handoff
  contract), `safety.md`, `uninstall.md`.
- **One module = one tool.** A module that bundles several independent tools cannot be
  partially installed, drifted, or uninstalled, because `record` replaces a whole
  service ID at once — the old `maintenance` module (fail2ban + swap + journald + Docker
  log rotation under one record) is why this rule is written down. Bundling belongs in
  SKILL.md's intent→module table, which maps one user goal to several modules; it does
  not belong inside a reference. A reference that installs two things a user could
  reasonably want separately is a reference that should be two files.
- **`templates/`** — the authoritative content for every *multi-line* file written to a
  host (nginx configs, systemd units, generated update scripts). Tokens are
  `@@NAME@@`, and each template's header comment lists **all** of its own tokens; a
  written file must be `grep -n '@@[A-Z]'`-clean before `nginx -t` / `daemon-reload`,
  because a leftover `@@SITE_ID@@` lands in the `# HAO-SITE:` header and makes
  `hao-guard.sh vhost-owner` report the site as a *different* site — after which that
  site can never update itself. **Every token's value must be a single line.** The
  token string also appears in the template's own comment header (the structure test
  requires it), and substitution is file-wide: a multi-line value leaves its first line
  inside the comment and turns the rest into live configuration outside any block, so
  `nginx -t` reports a "directive is not allowed here" that points nowhere near the
  cause. That is why the two "block-shaped" choices are one-line includes —
  `@@PORT80_BODY@@` picks between `snippets/redirect-to-https.conf` and the site's own
  body snippet — and why `@@DEFAULT@@` is a bare word appended to `listen 80`.
  Single-line artifacts (the four apt source lines, the
  `/etc/fstab` swap line) have no template; their content is given verbatim in the
  owning reference. Templates carrying secrets are rendered with
  `hao-secret.sh render`, never by reading a secret and interpolating it — note that
  render is all-or-nothing (every `@@KEY@@` in the template must exist in the
  credential file, so substitute structural tokens first) and defaults to mode 0640.
  Shared fragments (`snippets/ssl-hardening.conf`, `snippets/acme-challenge.conf`,
  `snippets/redirect-to-https.conf`, per-site body files) are written once and
  `include`d rather than duplicated into each server block.
- **Host paths are deliberately generic, with no `hao-` prefix**: `/opt/<site-id>` for
  source, `/var/www/<domain>` for a static docroot, `/etc/nginx/conf.d/<domain>.conf`,
  `/etc/nginx/snippets/<domain>.conf`, `/etc/systemd/system/<site-id>.service`,
  `/usr/local/bin/<site-id>-update`, certbot's `/etc/letsencrypt/live/<domain>/` for
  certs. The point is that a sysadmin who has never heard of HAO can maintain the result;
  a HAO-only layout locks the user in. **What must stay is the in-file
  `# Managed by HAO` / `# Service:` / `# HAO-SITE:` comment header** — `hao-guard.sh`
  reads file *contents*, not filenames, so generic naming costs nothing, but deleting
  those headers breaks ownership detection entirely. Marking generated files with a
  provenance comment is itself conventional (certbot writes `# managed by Certbot`).
- **Certificates go through certbot, not acme.sh**, and HAO installs only `certbot`
  (never `python3-certbot-nginx` — that plugin rewrites nginx config, fights the
  templates, and makes `drift` report constantly). Use `certonly --webroot`: certbot
  issues, templates configure. **Corollary that bit us once:** because the nginx plugin
  is never installed, `/etc/letsencrypt/options-ssl-nginx.conf` and
  `/etc/letsencrypt/ssl-dhparams.pem` never exist on a HAO host (`dpkg -S` shows the
  first belongs to `python3-certbot-nginx`; the second is copied into place by installer
  plugins only). A vhost that `include`s them fails `nginx -t` *after a successful
  issuance* — so all TLS parameters live in `snippets/ssl-hardening.conf` instead, and
  that snippet is the single authoritative place for protocols/ciphers/session/HSTS.
  Renewal needs no HAO involvement (`certbot.timer` ships with the package); the reload
  hook goes in `/etc/letsencrypt/renewal-hooks/deploy/` and is installed by the **nginx**
  module (it applies to every certificate, not to one site).
  Self-signed fallback goes to Debian's `/etc/ssl/certs` + `/etc/ssl/private`, never
  into `/etc/letsencrypt/`.
- **`scripts/`** — only four things stay deterministic, because improvising them
  breaks a guarantee:
  - `hao-secret.sh` — generates/reuses/injects credentials so values never enter the
    transcript. Reuses existing keys by default (that is the idempotency guarantee);
    refuses command-line literals because argv is world-readable via `/proc`.
  - `hao-state.sh` — writes `/var/lib/hao` state, computes drift, generates
    `HANDOFF.md` and `DEPLOY-INTENT.md`, and writes marker-block conventions into
    detected AI-assistant instruction files. The next agent must be able to *trust*
    this format. Three subcommands exist purely to make an *untrustworthy* record
    fixable, because every one of them was needed on a real host: `amend
    <svc> --result <word>` changes just the result word (using `record` for that
    means retyping every resource path, and a typo silently drops one); `services`
    flags results that aren't one of the five legal words (early versions wrote
    `success`, and nothing would have surfaced it); `orphans` lists files carrying
    the `# Managed by HAO` header that are in no `.resources` file — the header is
    the hook that makes a skipped `record` detectable at all. What no subcommand
    does is verify a service is *usable*: `record` only checks that the paths it was
    given exist, so a host once carried `docker installed` with no docker binary.
    That check belongs in the takeover procedure, not the script.
  - `hao-guard.sh` — read-only ownership checks before overwriting anything
    (`vhost-owner`, `managed-file`, `cert-issuer`, `repo-identity`, `port-free`,
    `unit-free`, `unit-port`, `os-supported`). `unit-free` exists because dropping the
    `hao-site-` unit prefix means `/etc/systemd/system/<name>.service` can silently
    override a distro unit — a site called `nginx` would shadow Nginx's own unit with no
    error. `vhost-owner` and `unit-free` share `classify_hao_file`.
  - `hao-remote.sh` — SSH transport and authentication, so the agent can run on a
    laptop and drive a server. Nine subcommands, none of which know about modules:
    `resolve`, `hostkey`, `bootstrap`, `probe`, `session`, `push`, `exec`, `cleanup`,
    `targets`. Design points worth keeping: **`$SKILL` is redefined as the remote
    directory**, which is what lets all 98 `"$SKILL/scripts/..."` call sites in the
    references stay unchanged — `exec` exports it and `cd`s into the pushed tree.
    **The bundle is pushed, not streamed**, because `hao-state.sh convention` reads its
    body from stdin and `bash -s` would break `-h` (`BASH_SOURCE` becomes `main`).
    **The bundle is gated on three checks** (`bash -n`, no `\r`, tree hash matches) —
    the CRLF one matters because the Windows worktree is CRLF and a `\r` shebang fails
    to exec. **Host keys are pinned per target in `~/.ssh/hao_known_hosts`**, never
    `accept-new`, because every guard in this skill answers *permissively* when pointed
    at the wrong host. **No secret values in argv**: scripts reach the remote via
    stdin; the bootstrap password goes through `ssh-copy-id` or `SSH_ASKPASS` reading a
    `0600` file. Two portability traps that cost real debugging time: MSYS `sha256sum`
    writes `hash *path` and Windows `sort` orders differently from GNU/Linux, so the
    tree hash must use `LC_ALL=C sort` and hash only the digest column; and
    `MSYS2_ARG_CONV_EXCL='*'` must **not** be set when calling the native `ssh.exe`,
    or `-o IdentityFile=/c/...` arrives un-translated and authentication silently fails.
- **Runtime state on a deployed host**: `/var/lib/hao/` (`HANDOFF.md`,
  `DEPLOY-INTENT.md`, `manifest.json` schema_version 1, `services/<svc>.json` +
  `.resources` + `.intent`); credentials live separately in `/etc/hao/<svc>.env`
  (files `0600`, directory `0700`). The split follows regenerability: `/var/lib` is
  discardable regenerable state that backup policy often excludes, credentials are not
  regenerable — regenerating one means changing a live password.
  `/var/lib/hao` is an **index, not a container**: vhosts live in `/etc/nginx`, units in
  `/etc/systemd/system`, apt sources in `/etc/apt`, because the programs consuming them
  dictate those paths. `manifest.json` is how you find out what HAO touched.
  `record` **replaces** a service ID's entry rather than appending, so anything a module
  can deploy more than once must carry an instance suffix in its service ID
  (`site-blog`, not `site`) — otherwise the earlier instance silently drops out of
  `drift`. `handoff` rebuilds `manifest.json` and `DEPLOY-INTENT.md`, which is what makes
  the uninstall flow (delete `services/<svc>.*`, then `handoff`) leave both consistent.
- **`intent` vs `record`**: `record` captures *what this host looks like now* and dies
  with the host. `intent` captures *how to rebuild an equivalent host* (repo, domain,
  type, branch, build command) and is the only thing worth carrying off-machine — so the
  closing report must tell the user to save `DEPLOY-INTENT.md` themselves. The intent
  file is `0644` and hands to the user, so it **must not contain credentials**: the
  script rejects secret-looking key names and redacts credentials embedded in URLs.
- **Ownership classes** (`managed` / `shared` / `observed` / `secret`) decide what a
  later agent may do to a resource. Choosing wrong has concrete costs: marking a user's
  code directory `managed` makes `drift` report false positives forever; marking
  someone else's config `managed` invites a future agent to overwrite it.
- **Scope boundary**: HAO installs the generic ops substrate (web server, runtimes,
  container engine, hardening) and deploys sites from the user's own Git repo. Procedures
  for specific third-party applications are deliberately **out of scope** — they each
  have their own bootstrap flow, default credentials and data-migration semantics, so a
  generic procedure produces plausible-looking wrong steps. `SKILL.md` has a checklist
  for the agent to apply when a user asks for one (default admin password, data
  location, tag pinning, loopback binding).

## Hard constraints

- **Hidden modules exist.** `tests/test-hidden-modules.sh` enforces that certain
  in-repo directories are never referenced from any public file (`*.md`, `*.sh`,
  `*.yml`, `*.yaml`, `*.json` outside those directories and `tests/`). Read that test
  to see the protected names — do not write them anywhere else, including this file.
  Those directories are self-contained and must not be given a `references/` doc.
- **The skill must stay runtime-neutral.** `tests/test-generic-skills.sh` forbids
  writing the skill for one specific agent runtime. Agent-instruction-file detection
  goes by *file convention* (existing `AGENTS.md` / `CLAUDE.md` under dot-directories)
  plus a `--agent-file` override, not by naming products.
- All scripts must pass `bash -n` and `shellcheck -x -S warning`. Files under
  `templates/` that are shell scripts must end in `.sh.tmpl`, not `.sh`, or CI's glob
  will lint their `@@TOKEN@@` placeholders and fail.
- **Never log or echo secret values.** Use `hao-secret.sh`; report only file paths.
- Procedures must stay idempotent (re-running must be safe) and must refuse rather
  than overwrite anything not owned by HAO.
- **What the tests do and don't cover**: script behavior and skill structure are
  tested; the *correctness of the prose procedures* is not — you cannot shellcheck a
  paragraph. After changing a `references/` procedure, verify it on a throwaway Ubuntu VM.
  Two suites do reach template *content*: `tests/test-nginx-config.sh` renders the nginx
  templates into a temp prefix and runs the real `nginx -t` (it caught the multi-line
  token bug above, and it is the only thing that can catch a directive that a given
  nginx version doesn't know — `http2 on;` needs >= 1.25.1, and the machine's nginx may
  be a distro package, not ours), and `tests/test-site-update.sh` renders the static
  update script and actually runs its failure branches.
- **Never substitute into config with `${var//pat/rep}`.** Bash's pattern substitution
  treats `&` in the *replacement* as "the matched text", and that behaviour was added in
  a later bash than some supported targets ship — so a credential containing `&` gets
  silently written as `...@@KEY@@...` while the script reports success, and the same
  script behaves differently on different hosts. Both renderers now use an explicit
  literal-split loop (`hao_subst_literal` / `subst_literal`); `tests/test-secret.sh` has
  the regression test.
- **Acceptance runs on Ubuntu only.** Debian 13/12 stay in the supported matrix but
  are not a release gate — GitHub-hosted runners have no Debian images, and containers
  can't exercise systemd/Docker realistically.

## Adding a module

1. Write `skills/hao-deploy/references/<module>.md` following the shape of an existing
   one: read-only checks first (with explicit refusal conditions), then install steps,
   then verification with real evidence, then `hao-state.sh record` + `handoff`, then
   common failures.
2. Add any host-written file to `templates/` with a `# Managed by HAO` +
   `# Service: <module>` header — `hao-guard.sh managed-file` depends on that header.
3. Add the module to the table in `SKILL.md` (an unreferenced reference fails the
   structure test).
4. Run `./tests/run.sh`, then verify on a throwaway Ubuntu VM.
