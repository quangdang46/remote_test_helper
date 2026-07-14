---
name: rth
description: >
  Drive multi-OS install/smoke/feature checks with rth (Remote Test Helper) on
  Mac + Windows + Ubuntu WSL over SSH. Use when the user wants to run the same
  command across lab hosts, set up OpenSSH/keys for the lab, retest an install
  link on Windows/WSL, matrix-smoke a CLI after a fix, parse rth --json output,
  or avoid clipboard-hopping logs between machines. Triggers on: rth, remote
  test helper, multi-OS smoke, matrix test, run on Windows/WSL/Mac, lab doctor,
  hosts.conf, install-link retest.
---

# rth — Remote Test Helper (agent skill)

`rth` runs the same install/smoke/feature command on a **Mac / Windows / Ubuntu WSL** lab over SSH and streams logs to the controller terminal. No shared TTY, no remote compile (that is `rch`).

Agents: always prefer **non-interactive flags** and **`--json`** when parsing. Never hang on password prompts (`BatchMode`).

## When to use

| Goal | Command pattern |
|------|-----------------|
| Lab bring-up / missing SSH | `rth guide --json` → `setup` → `doctor` |
| One host check | `rth run -e <env> -- '<cmd>'` |
| Same check on many hosts | `rth matrix -- '<cmd>'` |
| Save logs for CI/agents | `rth matrix --json --save -- '<cmd>'` |
| Health only | `rth doctor --json` |

## Contract (always)

| Stream / code | Meaning |
|---------------|---------|
| **stdout** | Remote command output (`[mac]` / `[win]` / `[ubuntu]` prefix on matrix) |
| **stderr** | `rth` diagnostics (SSH, config, timeouts) |
| **exit 0** | All selected envs succeeded |
| **exit 1** | Usage / config error |
| **exit 2** | Partial failure (some envs failed) |
| **exit 3** | All failed / unreachable (command not run on dead hosts) |
| **exit 4** | Timeout (reserved) |

Parse with `--json` when you need structure. Human chrome goes to stderr and is suppressed under `--json`.

## Preferred agent loop

### A) First-time / broken lab

```bash
rth guide --json                 # steps + pubkey + agent_instructions
rth setup --non-interactive      # if no ~/.config/rth/hosts.conf or key
# edit hosts.conf: set win_host / win_user (and ubuntu_* if WSL). Never keep 192.168.1.20 placeholder.
rth guide windows                # paste-ready OpenSSH + authorized_keys for the user
rth doctor --json                # iterate until green
rth matrix -- 'echo rth-ok'      # smoke
```

Rules for setup:

1. Execute `guide --json` steps in order; stop on failure and report.
2. Ask the user only for **Windows Admin** actions and unknown IP/username.
3. Use BatchMode SSH; never hang on password prompts.
4. Do **not** auto-disable Windows firewall without consent.
5. Do **not** commit private keys.
6. `guide` helps **set up faster** — it is not the daily test runner.

### B) Daily install → fix → retest

```bash
# Install-link style check (your real workflow)
rth run -e win -- 'curl -fsSL https://example.com/install.sh | bash -s -- --easy-mode'

# Did the binary land?
rth run -e win -- 'mycli --version'

# Same smoke on all three
rth matrix -- 'mycli --version'

# Feature-by-feature (logs already on controller — no clipboard hop)
rth run -e win -- 'mycli feature-a --tmp /tmp/rth'
rth matrix -- 'mycli self-test --tmp /tmp/rth-smoke'

# Optional structured save
rth matrix --json --save -- 'echo rth-ok'
```

On failure:

1. Read **stderr** + the failing env prefix on stdout.
2. Fix on the **controller** (or the remote host via a short `rth run`).
3. Re-run the same `run` / `matrix` command — do not ask the user to paste logs.

## Commands cheat sheet

```bash
rth guide [setup|windows|wsl|config|agent] [--json]
rth setup [--non-interactive] [--easy-mode]
rth doctor [-e env,...] [--json]
rth status [-e env,...]
rth list
rth run    -e <env> [--] <cmd...>
rth matrix [-e env,...] [--serial] [--] <cmd...>
rth ssh    <env>
```

### Global flags

| Flag | Effect |
|------|--------|
| `--json` | Machine-readable JSON on stdout |
| `--config PATH` | hosts.conf path (default `~/.config/rth/hosts.conf`) |
| `--save` | Also write `./logs/<ts>/<env>.log` |
| `--timeout N` | SSH/command timeout seconds (default 30) |
| `--shell cmd\|powershell` | Windows shell override |
| `-e, --env NAME` | Filter env(s), comma-separated |
| `-q, --quiet` | Less stderr chrome |
| `--serial` | matrix: run envs one-by-one |

Default env names: `mac`, `win`, `ubuntu` (from `RTH_ENVS` in hosts.conf).

## Config model

Config is shell-sourceable `key=value` at `~/.config/rth/hosts.conf` (see `config/hosts.example.conf`).

| Field pattern | Meaning |
|---------------|---------|
| `RTH_ENVS="mac,win,ubuntu"` | Inventory order |
| `<env>_kind` | `local` \| `ssh` \| `wsl` |
| `<env>_host` / `_user` / `_port` | SSH target (Windows IP for both `win` and `ubuntu` WSL hop) |
| `<env>_shell` | `bash` / `cmd` / `powershell` |
| `<env>_workdir` / `_logdir` | Remote working dirs |
| `ubuntu_distro` | WSL distro name (default `Ubuntu`) |
| `RTH_SSH_OPTS` | Shared SSH options (must keep `BatchMode=yes`) |

WSL path: `ssh win → wsl -d <distro> -- bash -lc "…"` (cmd-safe hop; unquoted distro + double-quoted bash -lc).

## Quoting rules (critical)

Cross-hop quoting is the main footgun: **ssh → cmd → wsl**.

- Keep remote commands **short and simple**.
- Prefer single-quoted remote payloads on the controller:  
  `rth run -e win -- 'curl --version'`
- Avoid nested quotes, complex pipelines, and heredocs in one shot.
- Prefer two steps over one clever line when WSL is involved.
- Do not rely on interactive prompts inside the remote command.

## Install (controller)

```bash
# Unix
curl -fsSL "https://raw.githubusercontent.com/quangdang46/remote_test_helper/main/install.sh?$(date +%s)" \
  | bash -s -- --easy-mode

# Windows PowerShell (window stays open)
irm "https://raw.githubusercontent.com/quangdang46/remote_test_helper/main/install.ps1" | iex
# if WSL hangs:  $env:RTH_FORCE_GITBASH="1"; irm ... | iex
```

From a checkout: put `bin/` on `PATH`, or run `bin/rth` with `RTH_ROOT` pointing at the repo.

## Do / Don't

**Do**

- Prefer `--json` + stable exit codes for agent loops.
- Run `doctor` before blaming the tool under test.
- Use `matrix --save` when you need durable evidence.
- Filter with `-e win` / `-e ubuntu` when only one host matters.

**Don't**

- Assume TTY prompts or password SSH.
- Treat `guide` as a substitute for `run`/`matrix`.
- Commit `~/.ssh/id_ed25519_rth` or rewrite firewall rules unattended.
- Send multi-line monster commands through the Windows/WSL hop.

## Related project docs

- `docs/AGENT.md` — short agent card
- `docs/SSH_WINDOWS.md` / `docs/SSH_WSL.md` — host setup detail
- `config/hosts.example.conf` — inventory template
- `README.md` — human overview + Agent Quickstart
