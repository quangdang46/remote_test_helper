# MASTER PLAN — `remote_test_helper` (`rth`)

> **Status:** v0.1.0 implemented (2026-07-13)  
> **Date:** 2026-07-13  
> **Language:** Bash CLI (v1)  
> **Sibling pattern:** `remote_compilation_helper` → `rch`  
> **Research note:** Exa MCP unavailable (auth required); plan grounded in RCH README/install, release-curl skill, OpenSSH Windows/WSL docs, and multi-host SSH prior art (pssh/fabric/ansible ad-hoc).

---

## 0. One-line mission

**From any of Mac Mini / Windows / Ubuntu (WSL), run the same checks on all hosts over SSH, stream logs to the terminal, so AI agents (and humans) can multi-OS test CLI tools without manual hopscotch.**

Not realtime terminal sync. Not remote compilation (that is RCH).

---

## 1. Problem statement

### Pain

When building tools for AI agents, validation requires **three environments**:

| Host | Network | Notes |
|------|---------|--------|
| **Mac Mini** | WiFi / LAN | Often primary dev; can also be controller |
| **Windows laptop** | WiFi / LAN | OpenSSH Server; shell default **cmd** |
| **Ubuntu** | WSL on the Windows machine | Prefer stable path first |

Today the loop is:

```text
run on Mac → copy to Win → check → copy to WSL → check → bug
→ fix on Mac → release → repeat
```

Agents burn time on environment switching; humans burn time pasting logs.

### Success criterion (v1)

An agent (or human) on **any** of the three machines can:

1. Install `rth` with a one-liner (`curl` / `irm`).
2. Complete `rth setup` + `rth doctor` until 3 hosts are green (SSH key-based).
3. Run:

```bash
rth matrix -- 'curl --version'
rth run -e win -- 'where mycli'
rth matrix -- 'mycli self-test --tmp /tmp/rth-smoke'
```

…and see **prefixed terminal logs** + reliable exit codes for fix → release → retest loops.

### Non-goals (v1)

| Non-goal | Why |
|----------|-----|
| Realtime shared TTY / tmux sync | Explicitly not needed |
| Transparent build offload | Use **RCH** (`remote_compilation_helper`) |
| Daemon / worker binary fleet | Overkill for 3 home-lab hosts |
| Full Windows native `.exe` without bash | Bash via Git Bash/WSL is enough for v1 |
| Auto-break Windows firewall/sshd without guidance | Semi-guided setup safer |
| 10-provider MCP auto-wire | RTH is a CLI, not an MCP server (v1) |

---

## 2. Positioning vs RCH and peers

### 2.1 vs `remote_compilation_helper` (`rch`)

| Dimension | RCH | RTH |
|-----------|-----|-----|
| Purpose | Offload **compile/test builds** to Linux workers | **Multi-OS check** any command |
| UX | Transparent hook + fail-open local | Explicit `rth run` / `matrix` |
| Targets | Linux workers + `rch-wkr` | Mac + Win + WSL |
| Stack | Rust daemon/hook | Bash + OpenSSH |
| Naming family | `remote_*_helper` | same family |

**Complementary:** RCH speeds builds; RTH proves the shipped CLI works on real Mac/Win/Linux shells.

### 2.2 Prior art (what to steal / avoid)

| Tool | Steal | Avoid for RTH |
|------|-------|----------------|
| **GNU Parallel / pssh** | Parallel SSH, host lists | Poor Windows story; not agent-ergonomic |
| **Fabric / Invoke** | Task abstraction | Python runtime dep; heavier |
| **Ansible ad-hoc** | Inventory model | YAML ceremony; agent-hostile for 3 hosts |
| **RCH install** | `curl\|bash`, `--easy-mode`, doctor, fail guidance | Daemon, hooks, fleet |
| **release-curl skill** | `install.sh` + `install.ps1`, PATH, flags, checksum patterns | Full Rust 5-target matrix (not needed pure bash) |

RTH = **tiny inventory + SSH exec + matrix labels + setup wizard**, optimized for **agent loops** and **3-OS lab**.

---

## 3. Users and workflows

### Primary users

1. **AI coding agents** (Claude, Codex, Cursor, …) running shell tools.
2. **You** driving the same CLI while debugging agent-built tools.

### Core workflows

#### W1 — First-time lab bring-up

```text
Install rth on controller → rth setup → edit hosts → key exchange
→ rth doctor until green → rth matrix -- 'echo ok'
```

#### W2 — Dependency / binary presence

```text
rth matrix -- 'curl --version'
rth run -e win -- 'where curl'
rth run -e ubuntu -- 'command -v curl'
```

#### W3 — CLI feature smoke (tmp)

```text
rth matrix -- 'mycli self-test --tmp /tmp/rth-smoke || mycli self-test --tmp %TEMP%\\rth-smoke'
# better: per-env command profiles later; v1 raw shell strings are OK
```

#### W4 — Bugfix release loop

```text
rth matrix -- 'mycli --version && mycli smoke'
# fail on win → fix on Mac → release/install on hosts → matrix again
```

#### W5 — Any machine as controller

Same config model on all three; `kind=local` for self, SSH for others.

---

## 4. Product decisions (locked from Q&A)

| # | Decision | Choice |
|---|----------|--------|
| 1 | Controllers | **All 3** can control |
| 2 | Language v1 | **Bash** |
| 3 | Logs | **Terminal stdout/stderr** (optional `--save` files) |
| 4 | Windows shell | Default **cmd**; escape hatch PowerShell |
| 5 | Ubuntu path | v1 default **via Windows + `wsl`**; optional direct SSH later |
| 6 | Name | Repo **`remote_test_helper`**, CLI **`rth`** |
| 7 | SSH keys | Not present yet → **`setup` is first-class** |
| 8 | Install | **curl** (Unix) + **irm** (Windows), learn RCH + release-curl |
| 9 | Realtime | **No** |

---

## 5. Architecture

### 5.1 Runtime topology

```text
                    ┌─────────────────────┐
                    │  Controller (any)   │
                    │  rth + hosts.conf   │
                    └─────────┬───────────┘
           ┌──────────────────┼──────────────────┐
           │                  │                  │
           v                  v                  v
     ┌──────────┐      ┌────────────┐     ┌────────────────┐
     │ mac      │      │ win        │     │ ubuntu (WSL)   │
     │ local or │      │ SSH :22    │     │ SSH win +      │
     │ SSH :22  │      │ cmd /c     │     │ wsl -d Ubuntu  │
     └──────────┘      └────────────┘     └────────────────┘
```

### 5.2 Execution model

```text
rth matrix -- CMD
  for each env in selection:
    resolve runner (local | ssh | wsl-via-ssh)
    wrap CMD for shell (bash -lc | cmd /c | wsl bash -lc)
    stream stdout/stderr with prefix [env]
    capture exit code
  aggregate exit: 0 all ok | 2 partial | 3 unreachable | 1 usage
```

### 5.3 Components (repo layout)

```text
remote_test_helper/
├── MASTER_PLAN.md          # this file
├── README.md
├── LICENSE
├── install.sh              # curl | bash
├── install.ps1             # irm | iex
├── bin/
│   └── rth                 # main entry (or thin wrapper)
├── lib/
│   ├── common.sh           # log, die, json, paths
│   ├── config.sh           # load hosts.conf, getters
│   ├── ssh.sh              # ssh opts, run remote, wsl wrap
│   ├── matrix.sh           # parallel/serial matrix runner
│   └── setup.sh            # setup wizard modules
├── config/
│   └── hosts.example.conf
├── docs/
│   ├── SSH_WINDOWS.md
│   ├── SSH_WSL.md
│   └── AGENT.md            # agent quick card
└── tests/
    └── smoke/              # local shellcheck + fake-ssh fixtures if possible
```

### 5.4 Config

**Path:** `XENV` → prefer `~/.config/rth/hosts.conf`  
**Override:** `RTH_CONFIG=/path/to/hosts.conf`

**Format:** shell-sourceable key=value (bash-native, no TOML parser).

```bash
RTH_ENVS="mac,win,ubuntu"

mac_kind="local"          # local | ssh
mac_label="Mac Mini"
mac_host=""
mac_user=""
mac_port="22"
mac_shell="bash"
mac_workdir="$HOME/agent-ws"

win_kind="ssh"
win_label="Windows Laptop"
win_host="192.168.x.x"
win_user="..."
win_port="22"
win_shell="cmd"           # cmd | powershell
win_workdir="C:/Users/.../agent-ws"

ubuntu_kind="wsl"         # wsl | ssh (direct later)
ubuntu_label="Ubuntu WSL"
ubuntu_host="192.168.x.x" # usually same as win
ubuntu_user="..."         # Windows user for hop
ubuntu_port="22"
ubuntu_distro="Ubuntu"
ubuntu_shell="bash"
ubuntu_workdir="~/agent-ws"

RTH_SSH_OPTS="-o ConnectTimeout=8 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
```

### 5.5 SSH strategy (research-backed)

#### Windows OpenSSH Server

- Install Optional Feature OpenSSH Server; start `sshd`; Automatic startup.
- Firewall allow port 22.
- **Key path footgun:**
  - Normal user: `C:\Users\<user>\.ssh\authorized_keys`
  - **Administrators group:** often must use `C:\ProgramData\ssh\administrators_authorized_keys` with strict ACL.
- Default shell may be PowerShell; RTH still wraps `cmd /c` for `win_shell=cmd`.

#### WSL Ubuntu (v1)

**Default path B — stable:**

```text
ssh user@windows 'wsl -d Ubuntu -- bash -lc "CMD"'
```

Pros: one port, no WSL IP portproxy churn.  
Cons: double quoting; depends on WSL running.

**Optional path A — direct SSH (phase 2):**

- sshd in WSL on port 2222 + Windows `portproxy` + firewall.
- WSL2 IP changes → refresh script on boot.
- `ubuntu_kind=ssh` + `ubuntu_port=2222`.

#### Key model (v1)

**Lab-simple:** one Ed25519 key per controller machine; public keys distributed to all targets.

`rth setup` steps:

1. Ensure `~/.ssh/id_ed25519` (or configured `IdentityFile`).
2. Print pubkey + copy instructions per OS.
3. Optional: `ssh-copy-id` where available; Windows manual paste guide.
4. `BatchMode` probe each host.
5. Write/update `hosts.conf`.

WiFi DHCP: document **DHCP reservation** or mDNS hostname; config stores host as IP or name.

---

## 6. CLI specification (v1)

### 6.1 Global

```text
rth [--json] [--config PATH] [-h|--help] [-V|--version] <command> ...
```

### 6.2 Commands

| Command | Behavior |
|---------|----------|
| `setup` | Wizard: dirs, example config, key gen, SSH checklists, smoke |
| `doctor` | Connectivity + shell smoke per env |
| `status` | Short online/OS/user summary |
| `list` | Env names from config |
| `run -e <env> -- <cmd...>` | One env; stream log |
| `matrix [-e a,b] -- <cmd...>` | Many envs; prefix `[env]`; aggregate exit |
| `ssh <env>` | Interactive SSH / local shell |

### 6.3 Flags

| Flag | Scope | Meaning |
|------|--------|---------|
| `-e, --env` | run, matrix, status, doctor | Filter envs |
| `--` | run, matrix | End of rth flags |
| `--json` | most | Machine-readable |
| `--save` | run, matrix | Also write `./logs/<ts>/<env>.log` |
| `--timeout N` | run, matrix, doctor | Seconds (default 30) |
| `--shell cmd\|powershell` | win only | Override win shell |
| `--serial` | matrix | Disable parallel (default parallel) |
| `--easy-mode` | setup / install only | PATH + non-interactive defaults where safe |

### 6.4 Exit codes

| Code | Meaning |
|------|---------|
| 0 | All selected envs succeeded |
| 1 | Usage / config error |
| 2 | Partial failure (some envs failed) |
| 3 | Unreachable / SSH auth failure (no command run) |
| 4 | Timeout |

### 6.5 Output conventions (agent-friendly)

Human:

```text
[mac] curl 8.7.1 ...
[win] curl 8.4.0 ...
[ubuntu] curl 7.81.0 ...
── matrix: 3 ok, 0 fail ──
```

JSON (`--json`):

```json
{
  "ok": true,
  "command": "curl --version",
  "results": [
    {"env": "mac", "ok": true, "exit": 0, "stdout": "...", "stderr": "", "duration_ms": 120},
    {"env": "win", "ok": true, "exit": 0, "stdout": "...", "stderr": "", "duration_ms": 340}
  ]
}
```

Stable fields only; no fancy schema churn in v1.

### 6.6 Explicitly deferred commands

| Command | Phase |
|---------|-------|
| `push` / `pull` (rsync/scp workdir) | **2** — critical for release loop; after SSH solid |
| `self-test` built-in multi-check suite | **2** |
| `capabilities` / `robot-docs` | **2** (RCH-style agent discovery) |
| Direct WSL SSH path automation | **2** |
| Parallel job cancel / queue | Never for v1 scope |

---

## 7. Install plan (curl + Windows)

### 7.1 UX targets

```bash
# macOS / Linux / WSL / Git Bash
curl -fsSL "https://raw.githubusercontent.com/<owner>/remote_test_helper/main/install.sh?$(date +%s)" | bash -s -- --easy-mode
```

```powershell
# Windows PowerShell
irm "https://raw.githubusercontent.com/<owner>/remote_test_helper/main/install.ps1" | iex
```

### 7.2 `install.sh` (learn RCH + release-curl)

Must have:

- `set -euo pipefail`, umask, lock, cleanup trap
- Flags: `--easy-mode`, `--dest`, `--version`, `--quiet`, `--uninstall`, `--verify`, `--help`
- Install atomic to `${DEST:-$HOME/.local/bin}/rth` (+ optional `lib` under `~/.local/share/rth` or embed single-file for simplicity)
- **v1 preferred delivery:** single-file `bin/rth` (libs inlined or `RTH_ROOT` next to script) to minimize install complexity
- Fallback chain: release tarball → raw GitHub files from `main` → fail with clone instructions
- Easy-mode: append PATH to `.zshrc`/`.bashrc` if missing
- Post-install: print `rth setup` / `rth doctor`
- **No** daemon, **no** MCP mass-config (v1)

### 7.3 `install.ps1` (learn release-curl; RCH lacks this)

- `irm | iex` safe patterns; `-EasyMode`, `-Dest`, `-Uninstall`, `-Verify`
- Prefer install **into WSL** if present: `wsl -e bash -lc 'curl … install.sh'`
- Else Git Bash: place scripts under user profile + `rth.cmd` shim invoking bash
- Else clear error: need WSL or Git Bash for bash CLI
- User PATH update via `[Environment]::SetEnvironmentVariable`

### 7.4 Release strategy (bash)

| Phase | Approach |
|-------|----------|
| 0 (bootstrap) | Raw `main` install only |
| 1 | Tag `v0.x.y` + attach `rth-vX.Y.Z.tar.gz` + `.sha256` (scripts bundle) |
| 2 | Optional CI shellcheck + smoke; **no** Rust matrix required |

---

## 8. Setup wizard detail (`rth setup`)

### Modes

- Interactive (default TTY)
- `--non-interactive`: write example config + print checklists; exit 0 with “next steps”

### Steps

1. Detect OS (macOS / Linux / WSL / Windows-via-bash)
2. Create `~/.config/rth/`, copy example if missing
3. Prompt or leave placeholders for hosts/users/IPs
4. Ensure SSH key (`ssh-keygen -t ed25519 -N '' -f …` only if confirmed / easy-mode lab)
5. Print **per-target** checklist:
   - Mac: Remote Login / sshd
   - Windows: OpenSSH Server, firewall, authorized_keys path (Admin vs user)
   - WSL: `wsl -l -v`, distro name, optional sshd later
6. Optional pubkey copy helpers
7. Run `doctor` subset
8. Offer sample matrix: `echo rth-ok && uname -a || ver`

### Docs companions

- `docs/SSH_WINDOWS.md` — Admin key ACL, `sshd` service, firewall
- `docs/SSH_WSL.md` — via-win vs direct 2222
- `docs/AGENT.md` — 15-line agent card: commands, exit codes, examples

---

## 9. Implementation phases

### Phase 0 — Plan freeze (this doc)

- [x] Name, scope, CLI surface, install UX, SSH topology
- [ ] Owner GitHub username / repo visibility decision
- [ ] Confirm ubuntu default stays `wsl-via-win`

### Phase 1 — Skeleton + local run (no multi-host yet)

**Deliverables:**

- Single entry `bin/rth` with subcommands stub
- `lib/common.sh`, `config.sh`
- `list`, `status` (local only), `--help`, `--version`
- `config/hosts.example.conf`
- shellcheck clean on macOS

**Exit:** `rth list` works with example config; `rth run -e mac -- uname` works for `kind=local`.

### Phase 2 — SSH run + matrix

**Deliverables:**

- `ssh.sh`: BatchMode, timeout, quoting helpers
- `run` remote for `kind=ssh`
- `matrix` serial then parallel (bash background jobs + wait)
- prefix logging + exit aggregate
- `--json`, `--save`, `--timeout`
- Windows `cmd /c` quoting tests (document limits)
- Ubuntu `wsl` hop

**Exit:** From Mac Mini, matrix reaches win + ubuntu when keys exist.

### Phase 3 — Setup + doctor

**Deliverables:**

- `setup` wizard + non-interactive
- `doctor` probes (ssh, echo, shell identity)
- docs SSH_WINDOWS / SSH_WSL / AGENT
- actionable errors (`RTH-E001` style optional but nice)

**Exit:** New machine can follow setup docs to green doctor without reading source.

### Phase 4 — Installers

**Deliverables:**

- `install.sh` production-grade (release-curl patterns, RTH-slim)
- `install.ps1` WSL-first + Git Bash fallback
- README install section
- Optional first GitHub Release bundle

**Exit:** Curl one-liner installs on Mac + WSL; irm works or fails with clear message.

### Phase 5 — Hardening + phase-2 features gate

**Deliverables:**

- shellcheck CI (GitHub Actions ubuntu+macos)
- smoke tests with mocked ssh if feasible
- Decide go/no-go: `push`/`pull`, direct WSL SSH, `capabilities`

**Exit:** Tag `v0.1.0`.

### Phase 6+ (backlog)

- `rth push` / `pull` for release loop binaries
- `rth self-test` curated suite
- Direct WSL SSH setup automation
- TOON/json dual output if agent ecosystem wants it
- Optional tiny Rust rewrite only if bash quoting/Windows pain is unbearable

---

## 10. Quoting & Windows reality (risk register)

| Risk | Impact | Mitigation |
|------|--------|------------|
| Nested quotes `ssh → cmd → …` | Commands break | Prefer simple argv; document “keep commands simple”; optional base64 carrier later |
| Admin authorized_keys path | Key auth mysteriously fails | Setup docs + doctor message detecting permission denied |
| WSL not running | ubuntu env fail | doctor detects; suggest `wsl -e true` from win |
| WiFi IP churn | SSH host wrong | Prefer hostname / DHCP reservation; doctor shows configured host |
| Parallel matrix log interleave | Hard to read | Default prefix per line; `--serial` option |
| Password auth in agent | Hangs | BatchMode=yes; doctor says “enable keys” |
| Git Bash vs PowerShell PATH | `rth` not found | install.ps1 PATH + shim |
| Exa research incomplete | Missed prior art | Re-run when Exa auth fixed; not blocking v1 |

---

## 11. Testing strategy

| Layer | What |
|-------|------|
| Static | `shellcheck -x bin/rth lib/*.sh install.sh` |
| Unit-ish | Pure functions: json_escape, env list parse, exit aggregate |
| Integration local | `kind=local` run/matrix on controller |
| Integration lab | Real Mac↔Win↔WSL once keys exist (manual checklist in docs) |
| Installer | Dry-run DEST=tmp; uninstall cleans |

No requirement for Docker Windows in CI v1.

---

## 12. Agent ergonomics checklist

From RCH / agent-CLI lessons, RTH v1 must:

- [x] Non-interactive flags (no mandatory prompts for `run`/`matrix`)
- [x] Stable exit codes
- [x] `--json` on critical commands
- [x] `--help` with examples
- [ ] `docs/AGENT.md` short card
- [ ] Errors include next action (“run rth doctor”, “check authorized_keys Admin path”)
- [ ] Idempotent setup where possible

---

## 13. Security baseline

- SSH only; no custom network daemon in v1
- Prefer key auth; BatchMode for automation
- Do not log private keys
- setup never force-disables Windows firewall silently
- Commands run as remote user privileges — document trust model (you control the three machines)
- Optional later: allowlist of command prefixes for paranoid mode (not v1)

---

## 14. README outline (when implementing)

1. Hero: problem + one-liner install  
2. TL;DR workflows  
3. Install (curl + irm)  
4. Quick start (`setup` → `doctor` → `matrix`)  
5. Config reference  
6. CLI reference  
7. SSH notes (Win Admin keys, WSL hop)  
8. vs RCH  
9. Limitations  
10. License  

---

## 15. Open decisions (need your call before / during Phase 0)

| ID | Question | Default if silent |
|----|----------|-------------------|
| O1 | GitHub owner/repo public? | Your account / public when ready |
| O2 | Single-file `rth` vs multi-lib install | **Single-file preferred** for install simplicity; libs OK if `RTH_ROOT` co-located |
| O3 | Matrix default parallel or serial? | **Parallel** with `--serial` |
| O4 | Include `push` in v0.1 or strict phase 2? | **Phase 2** (after doctor green) |
| O5 | ubuntu default hop | **wsl-via-win** |

---

## 16. Suggested implementation order (agent swarm ready)

```text
P1  bin/rth CLI skeleton + config load + local run
P2  ssh + wsl hop + matrix + json/save
P3  setup + doctor + docs
P4  install.sh + install.ps1 + README
P5  shellcheck CI + tag v0.1.0
```

Each phase is independently demoable.

---

## 17. Definition of Done — v0.1.0

1. `curl | bash --easy-mode` installs `rth` on Mac Mini and WSL.  
2. `install.ps1` installs into WSL or documents Git Bash path.  
3. With valid `hosts.conf` + keys: `rth doctor` → 3 green (or clear red reasons).  
4. `rth matrix -- 'echo rth-ok'` prints three prefixed lines, exit 0.  
5. `rth run -e win -- 'echo %OS%'` works via cmd.  
6. `rth run -e ubuntu -- 'uname -a'` works via WSL hop.  
7. shellcheck clean; LICENSE + README present.  
8. Explicit doc: not a substitute for RCH; no realtime TTY claim.

---

## 18. Research appendix

### Sources used

- [remote_compilation_helper README](https://github.com/Dicklesworthstone/remote_compilation_helper) — positioning, CLI ergonomics, install UX  
- RCH `install.sh` patterns — easy-mode, lock, checksum, fail guidance  
- `release-curl` skill — `install.sh`/`install.ps1` production patterns, PATH, flags  
- Microsoft OpenSSH key management — Windows authorized_keys Admin path  
- WSL SSH community guides — port 2222 + portproxy vs hop via `wsl.exe`

### Exa

**Not run** — MCP server `exa` requires auth in this environment. When available, re-query:

- “SSH multi-host CLI for developer machine matrix testing”
- “Windows OpenSSH administrators_authorized_keys ACL pitfalls 2024–2026”
- “WSL2 SSH from LAN portproxy maintain”

Fold findings into `docs/` without changing v1 scope unless a hard blocker appears.

---

## 19. Next human checkpoint

Reply with:

1. **Approve plan** / request edits  
2. Answers to **O1–O5** if not defaults  
3. Whether to **implement Phase 1** next (skeleton only)

No code beyond this plan until you say go.
