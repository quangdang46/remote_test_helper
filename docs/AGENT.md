# Agent card — rth

## When to use

Multi-OS smoke/install/feature checks on Mac + Windows + Ubuntu WSL without pasting logs.

## Setup (agents first)

```bash
rth guide --json              # structured steps + pubkey + agent_instructions
rth guide                     # full human/agent playbook
rth guide windows             # paste-ready OpenSSH + authorized_keys
rth setup --non-interactive   # create config + key
rth doctor
```

`guide` is for **helping the user set up faster** — not for running remote tests.

## Commands

```bash
rth doctor --json
rth run -e win -- 'curl --version'
rth matrix -- 'echo rth-ok'
rth matrix --json --save -- 'mycli --version'
```

## Contract

| Stream | Meaning |
|--------|---------|
| stdout | Remote output (`[env]` prefix on matrix) |
| stderr | rth diagnostics |
| exit 0 | all ok |
| exit 2 | partial fail |
| exit 3 | all fail / unreachable |
| exit 1 | usage / config |

## Rules

- Prefer non-interactive flags; never assume TTY prompts.
- Keep remote commands short (quoting: ssh → cmd → wsl).
- On fail: read stderr + env prefix, fix on controller, re-run matrix/run.
- Setup SSH first: `rth setup` then `rth doctor`.
