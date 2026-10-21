# Security Policy

## What HAO is, in security terms

HAO is an **AI agent skill**, not a program. There is no CLI and no installer. The
deployment procedures live as prose in `skills/hao-deploy/references/` and are executed
by an agent, as root, either on the host it is running on or on a remote host it reaches
over SSH. Four small scripts under `skills/hao-deploy/scripts/` are the only
deterministic parts.

That shape decides how the guarantees below are enforced. Some are enforced *in code*
(the scripts refuse to do the unsafe thing). The rest are **behavioural rules the
executing agent must follow**, written down in `references/safety.md`. We say which is
which, because a rule that only exists in prose can be broken by a careless agent and
you should know that when you decide to run this.

## Supported environments

Debian 13/12 and Ubuntu 26.04/24.04/22.04 LTS. `hao-guard.sh os-supported` returns
`unsupported` for anything else and the procedures require the agent to stop there.

Release acceptance is performed on Ubuntu only. Debian remains a supported install
target but is not a release gate: GitHub-hosted runners have no Debian images, and
containers cannot realistically exercise systemd or Docker.

## Secret-handling contract

**Enforced in `scripts/hao-secret.sh`:**

- Generated credentials are written only to per-service files created atomically with
  `0600` permissions. The value is never printed to stdout — the script reports the file
  path and the key *names* only.
- **The credential directory is created `0700`.** File contents are already protected by
  `0600`, but a listable directory lets any local user enumerate which services hold
  credentials. An existing directory is never `chmod`ed — the write target could sit
  directly under `/etc`, and tightening that would be far worse than the metadata leak —
  so a pre-existing permissive directory produces a warning naming the fix instead.
- **Command-line literals are refused.** `KEY=hunter2` is rejected with an explanation,
  because argv is world-readable via `ps` and `/proc/<pid>/cmdline`. User-supplied
  secrets must come in as `KEY=@file:PATH` or `KEY=@env:VARNAME`.
- **Re-running does not rotate.** Existing keys in the target file are reused by
  default; rotation requires an explicit `--rotate KEY`. Keys already in the file but
  absent from the current invocation are preserved rather than dropped, because
  silently losing a credential a live service is using is an unacceptable failure.
- Injecting a secret into a config file goes through `hao-secret.sh render`, which
  substitutes `@@KEY@@` placeholders without printing any value, and refuses to write a
  half-populated file if the credential file is missing a key the template needs.

**Enforced in `scripts/hao-state.sh`:**

- State records contain only resource paths, ownership classes and content hashes.
  Resources classed `secret` are recorded with the hash literally `redacted` and are
  never hashed or read.
- `credentials` lists credential file *paths* and nothing else.
- **The deployment-intent file cannot carry a credential.** `DEPLOY-INTENT.md` is `0644`
  and is explicitly handed to the user to store off-machine, so `intent` rejects
  secret-looking key names (`*password*`, `*token*`, `*secret*`, `*apikey*`,
  `*credential*`, …) and redacts credentials embedded in URLs
  (`https://user:token@host/…` → `https://***@host/…`) in both the generated document
  and the on-disk record.

## Remote mode: the control plane moves to the laptop

When HAO drives a server over SSH, the machine running the agent is no longer the
machine being changed. That shift is what the guarantees below exist to contain.

**Enforced in `scripts/hao-remote.sh`:**

- **Host keys are pinned, never trusted on first use.** `bootstrap` requires an explicit
  `--fingerprint SHA256:…` that matches what `hostkey` reported, and refuses outright when
  the host already has a *different* key in `~/.ssh/hao_known_hosts`. A changed host key
  means the machine was reimaged or something is impersonating it; treating that as
  "update the entry" would remove the only control that detects a wrong target. Every
  later connection uses `StrictHostKeyChecking=yes` with that file, passed as `-o` so a
  permissive `StrictHostKeyChecking no` in the user's own config cannot leak in.
- **The bootstrap password never enters argv, a log, or the transcript.** The default
  path prints an `ssh-copy-id` command for the user to run, so ssh reads the password
  from its own tty. The opt-in `--askpass` path reads a user-created `0600` file through
  `SSH_ASKPASS`, passing only the *path* via an environment variable, and deletes the
  file afterwards. On Windows the permission check uses the NTFS ACL, because `chmod` on
  a Git Bash checkout is cosmetic.
- **A dedicated key is used, never the user's personal keys.** `~/.ssh/hao_ed25519` is
  generated if absent and left untouched if present. Reusing an existing personal key
  would make "which doors does this key open" unauditable across a fleet.
- **The pushed bundle is verified before it is used.** The remote copy must pass
  `bash -n` on every script, contain no `\r` (a CRLF shebang fails to exec on Linux and
  a CRLF `set -euo pipefail` is rejected as an invalid option), and hash to the same tree
  digest as the client. A partial or corrupted upload is refused rather than half-run.
- **The remote scratch directory is randomly named and self-owned.** `mktemp -d` under
  `/tmp` with mode `0700`; a reused directory is accepted only if it is not a symlink,
  is owned by the login user, and carries our marker. Deletion refuses anything that
  fails those checks, so `cleanup` cannot be tricked into removing someone else's tree.

**Behavioural rule for the agent** (`references/remote.md`):

- **Confirm the target identity before the first write.** `probe` reports the remote
  hostname, public IP, OS and a machine identity hash, and the agent must read those back
  to the user. This is not ceremony: on the wrong machine `hao-guard.sh` answers `free`,
  `managed-file` says `missing`, `repo-identity` says `absent`, and `record` silently
  skips paths that do not exist. Every guard in this skill is *permissive when run
  against the wrong host*, so pinned host keys plus a human confirmation are the only two
  controls that catch it.

## Where things live, and why

| Class | Regenerable? | Meant to be readable? | Location |
|---|---|---|---|
| State index, handoff doc, deployment intent | yes (re-run `record` / `intent`) | yes (`0644`) | `/var/lib/hao` |
| Credentials | **no** — regenerating one changes a live password | no (`0600`, dir `0700`) | `/etc/hao` |
| Config consumed by other programs | yes | varies | wherever that program requires |

The split is deliberate. `/var/lib` is conventionally discardable regenerable state that
backup and configuration-management policy often excludes wholesale; credentials must
survive. Mixing `0600` secrets into a tree whose `NOTICE`, `HANDOFF.md` and
`manifest.json` are *deliberately* world-readable would put two exposure classes in one
place.

`/var/lib/hao` is an **index, not a container**. It does not hold the deployed resources,
only the record of where they are and who owns them. Nginx vhosts, systemd units and apt
sources live where those programs require, and cannot be consolidated.

Secrets are deliberately **not** kept under a user's home directory. Under `sudo` there
is no single unambiguous home, so a per-user layout would fragment one machine's record
across several users; `0600 root:root` under `/etc` also means the deploying
(non-root) user cannot read a database password without escalating, which a home-directory
layout gives up by construction.

**Behavioural rules for the executing agent** (`references/safety.md`):

- Never print, echo or paraphrase the contents of a credential file. Report paths.
- The one sanctioned exception is passing a value to a program that cannot be served by
  `render` (deep-merging JSON is the only current case): the value goes through an
  environment variable, never argv, never stdout, never the report.
- Repository URLs may embed tokens; logs and reports redact them
  (`sed -E 's#(://)[^/@]+@#\1***@#'`).
- If the user pastes a password into the conversation, do not repeat it; point out that
  it is now in the transcript.

## Deployment hardening

- Services bind to `127.0.0.1` and are reached through the managed Nginx reverse proxy
  with TLS. Do not expose application ports directly to the internet. HAO cannot force an
  application's bind address, so after starting a Node site it reads the actual listening
  address back and tells the user plainly if the app bound `0.0.0.0` — in that state only
  the cloud firewall is keeping the port private.
- **Certificates go through certbot** (`certonly --webroot`), so they live in
  `/etc/letsencrypt/live/<domain>/` with the permissions certbot sets, and renewal is
  handled by the `certbot.timer` that ships with the package — HAO does not roll its own
  renewal. The nginx reload hook goes in `/etc/letsencrypt/renewal-hooks/deploy/` and
  refuses to reload when `nginx -t` fails. `python3-certbot-nginx` is deliberately **not**
  installed: it rewrites nginx configuration, which would fight HAO's templates.
- Self-signed fallback certificates go to Debian's `/etc/ssl/certs` (`644`) and
  `/etc/ssl/private` (`600`, directory `0700`), never into `/etc/letsencrypt/`.
- `/.well-known/acme-challenge/` stays reachable on port 80 so renewal does not break.
- **80→443 redirect requires three conditions**, all of them: a real Let's Encrypt
  certificate (not the self-signed fallback), the user not having opted out, and the
  user having confirmed that the cloud firewall / security group allows 443/TCP.
  Enabling a redirect to an unreachable 443 takes a working site completely offline
  (the classic Cloudflare 522). Self-signed certificates never redirect.
- Procedures must refuse rather than overwrite. `hao-guard.sh` answers "who owns this?"
  read-only (`vhost-owner`, `managed-file`, `cert-issuer`, `repo-identity`, `unit-free`),
  and `foreign` / `not-git` / `remote-mismatch` require the agent to stop and report the
  path rather than delete or overwrite anything.
- **`unit-free` guards a hazard created by using conventional names.** Site units are
  called `<site-id>.service` with no prefix, and `/etc/systemd/system/<name>.service`
  silently *overrides* a distro unit of the same name — a site called `nginx` would
  shadow Nginx's own unit with no error at all. Writing a unit without checking first is
  a defect, not a style choice.
- HAO does not change the SSH port, disable password login, or alter firewall default
  policy on its own initiative — those can lock the user out of their own machine with
  no second way in.

## Generic layout is a security property, not just ergonomics

Everything HAO writes to a host goes to a conventional location with a conventional name:
`/opt/<site-id>`, `/var/www/<domain>`, `/etc/nginx/conf.d/<domain>.conf`,
`/etc/nginx/snippets/`, `/etc/systemd/system/<site-id>.service`,
`/etc/letsencrypt/live/<domain>/`. A HAO-specific layout would mean that when something
goes wrong, only someone who knows HAO can audit or fix it — and the users HAO targets
are precisely those who will hand the machine to someone else.

What is *not* generic, deliberately, is the provenance header inside each generated file
(`# Managed by HAO` / `# Service:` / `# HAO-SITE:`). Ownership detection reads file
contents rather than filenames, so generic naming costs nothing — but removing those
headers would leave HAO unable to distinguish its own files from a stranger's, which is
what the refuse-rather-than-overwrite guarantee rests on. Marking generated files this way
is itself standard practice (certbot writes `# managed by Certbot`).

## Third-party applications are out of scope

HAO deliberately ships **no procedure for installing specific third-party
applications**. Those applications each have their own bootstrap flow, and some ship
with a **default administrator password that is live from the moment the service
starts** — a generic "deploy it behind TLS" procedure would put such a service on the
public internet before the user has changed it.

If you use HAO's `docker` + `nginx` modules as a substrate for such an application,
changing any upstream default credential before the service becomes publicly reachable
is **your responsibility**. `SKILL.md` requires the agent to raise this explicitly.

## Threat model, stated plainly

- **The agent runs as root and can execute user-supplied build commands.** Deploying a
  site runs that repository's build command on your host. That is arbitrary code
  execution by design; only deploy repositories you trust.
- **Prose procedures are not verified by CI.** Script behaviour and skill structure are
  tested; you cannot shellcheck a paragraph. A change to a `references/` procedure is
  verified by running it on a throwaway VM, not by the test suite.
- **The transcript is a secret-bearing artifact.** The contract above keeps generated
  credentials out of it, but anything the user types into the conversation is in it.
  This is why the remote flow never asks for a password in the chat: a pasted password
  is persisted to the local transcript and sent to the model provider, and changing it
  afterwards requires the user to notice and act.
- **In remote mode the server is a supply-chain input.** The agent runs whatever the
  server reports — `os-release`, command output, file contents. A compromised server can
  lie about all of it. The pinned host key is what makes "this is not the machine I
  connected to last time" detectable; it does not make a hostile machine trustworthy.
- **Remote commands arrive as text.** Each `exec` is a fresh SSH connection; the remote
  command string is assembled client-side and sent as the command argument, never
  streamed into a local shell. Secret *values* never appear in it — they travel on stdin
  or through `hao-secret.sh` on the remote side.

## Reporting a vulnerability

Report suspected vulnerabilities privately to the repository maintainers via a GitHub
[private security advisory](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository, or by opening a minimal issue that requests a private channel
**without** including exploit details or secrets. Please allow a reasonable window for a
fix before any public disclosure.
