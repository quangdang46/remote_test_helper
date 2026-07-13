#!/usr/bin/env bash
# rth guide — agent-oriented setup playbooks
# shellcheck shell=bash

rth_guide_pubkey() {
  local pub=""
  for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$f" ]]; then
      pub="$(tr -d '\n' <"$f")"
      printf '%s' "$pub"
      return 0
    fi
  done
  printf ''
}

rth_guide_cfg_path() {
  printf '%s' "${XDG_CONFIG_HOME:-$HOME/.config}/rth/hosts.conf"
}

# Human playbook
rth_guide_print_setup() {
  local cfg pub
  cfg="$(rth_guide_cfg_path)"
  pub="$(rth_guide_pubkey)"

  cat <<EOF
# rth guide — lab bring-up (for AI agents + humans)

Goal: 3 hosts green via \`rth doctor\`, then \`rth matrix -- 'echo rth-ok'\`.

## Agent rules
1. Run commands yourself when possible; only ask the user for Windows Admin steps you cannot reach.
2. Prefer: \`rth guide --json\` for structured steps, then execute in order.
3. After each step, verify (command in step). On fail, stop and explain.
4. Do NOT invent Windows IPs/users — read or ask, then edit hosts.conf.
5. Never paste private keys. Only use *.pub.

## Step 1 — Install rth (controller = usually Mac)
\`\`\`bash
curl -fsSL "https://raw.githubusercontent.com/quangdang46/remote_test_helper/main/install.sh?\$(date +%s)" \\
  | bash -s -- --easy-mode --verify
# or from repo: ./install.sh --easy-mode --verify
\`\`\`
Verify: \`rth --version\`

## Step 2 — Bootstrap config + SSH key (Mac)
\`\`\`bash
rth setup --non-interactive
\`\`\`
Creates: \`${cfg}\`
Ensures: \`~/.ssh/id_ed25519\` (+ .pub)

## Step 3 — Edit hosts.conf (Mac)
File: \`${cfg}\`

Set at least:
\`\`\`bash
win_host="<Windows LAN IP or hostname>"
win_user="<Windows username>"
ubuntu_host="<same as win_host usually>"
ubuntu_user="<same as win_user>"
ubuntu_distro="Ubuntu"   # must match: wsl -l -v on Windows
\`\`\`
mac_kind can stay \`local\` if controller is this Mac.

## Step 4 — Windows: OpenSSH Server (user on Windows, Admin PowerShell)
Paste-ready:
\`\`\`powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
Get-Service sshd
\`\`\`

## Step 5 — Windows: install this public key
EOF

  if [[ -n "$pub" ]]; then
    cat <<EOF

**Public key from this machine (one line):**
\`\`\`
${pub}
\`\`\`

### A) Normal user (not relying on Admin-only path)
\`\`\`powershell
\$ak = "\$env:USERPROFILE\\.ssh\\authorized_keys"
New-Item -ItemType Directory -Force -Path "\$env:USERPROFILE\\.ssh" | Out-Null
Add-Content -Path \$ak -Value '${pub}'
icacls \$ak /inheritance:r
icacls \$ak /grant:r "\$env:USERNAME:(R)"
\`\`\`

### B) User is in Administrators (common footgun)
\`\`\`powershell
\$ak = "C:\\ProgramData\\ssh\\administrators_authorized_keys"
Add-Content -Path \$ak -Value '${pub}'
icacls \$ak /inheritance:r
icacls \$ak /grant "SYSTEM:(F)"
icacls \$ak /grant "Administrators:(F)"
Restart-Service sshd
\`\`\`
EOF
  else
    cat <<'EOF'

No pubkey found yet. Run:
```bash
rth setup --non-interactive
cat ~/.ssh/id_ed25519.pub
```
Then put that line on Windows (see docs/SSH_WINDOWS.md).
EOF
  fi

  cat <<'EOF'

## Step 6 — WSL (Ubuntu on Windows)
```powershell
wsl -l -v
wsl -e true
```
Ensure `ubuntu_distro` in hosts.conf matches the NAME column.

## Step 7 — Verify from Mac
```bash
rth doctor
rth run -e win -- 'echo win-ok'
rth run -e ubuntu -- 'uname -a'
rth matrix -- 'echo rth-ok'
```

## If doctor fails
| Symptom | Next action |
|---------|-------------|
| win Permission denied | Admin authorized_keys path + ACL; restart sshd |
| win timeout / unreachable | wrong win_host, firewall, OpenSSH not running |
| ubuntu fail, win ok | `wsl -e true`; fix ubuntu_distro name |
| hang | BatchMode needs key auth (no password prompt) |

## Day-to-day (after green doctor)
```bash
rth run -e win -- 'curl --version'
rth matrix -- 'mycli --version'
rth run -e win -- 'curl -fsSL https://…/install.sh | bash'
```

Topics: `rth guide windows` · `rth guide wsl` · `rth guide config` · `rth guide agent` · `rth guide --json`
EOF
}

rth_guide_print_windows() {
  local pub
  pub="$(rth_guide_pubkey)"
  cat <<EOF
# rth guide windows

Run on **Windows** (Admin PowerShell where noted).

## 1. OpenSSH Server
\`\`\`powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
Get-Service sshd
\`\`\`

## 2. Public key from controller
EOF
  if [[ -n "$pub" ]]; then
    echo '```'
    echo "$pub"
    echo '```'
  else
    echo 'On Mac: `cat ~/.ssh/id_ed25519.pub` then paste below.'
  fi
  cat <<EOF

## 3a. Normal authorized_keys
\`\`\`powershell
New-Item -ItemType Directory -Force -Path \$env:USERPROFILE\\.ssh | Out-Null
# Add-Content the pubkey line to \$env:USERPROFILE\\.ssh\\authorized_keys
icacls \$env:USERPROFILE\\.ssh\\authorized_keys /inheritance:r
icacls \$env:USERPROFILE\\.ssh\\authorized_keys /grant:r "\$env:USERNAME:(R)"
\`\`\`

## 3b. Administrators group (try this if 3a fails)
\`\`\`powershell
# File: C:\\ProgramData\\ssh\\administrators_authorized_keys
icacls C:\\ProgramData\\ssh\\administrators_authorized_keys /inheritance:r
icacls C:\\ProgramData\\ssh\\administrators_authorized_keys /grant "SYSTEM:(F)"
icacls C:\\ProgramData\\ssh\\administrators_authorized_keys /grant "Administrators:(F)"
Restart-Service sshd
\`\`\`

## 4. From Mac
\`\`\`bash
ssh -o BatchMode=yes USER@WIN_IP "cmd /c echo ok"
rth -e win doctor
\`\`\`
EOF
}

rth_guide_print_wsl() {
  cat <<'EOF'
# rth guide wsl

v1 path: SSH → Windows (cmd) → `wsl -d <distro> -- bash -lc "…"`

## On Windows
```powershell
wsl -l -v
wsl -e true
```

## In hosts.conf
```bash
ubuntu_kind="wsl"
ubuntu_host="<same as win_host>"
ubuntu_user="<same as win_user>"
ubuntu_distro="Ubuntu"   # exact name from wsl -l -v
```

## From Mac
```bash
rth run -e ubuntu -- 'uname -a'
rth doctor -e ubuntu
```

Direct WSL SSH (port 2222) is phase 2 — see docs/SSH_WSL.md.
EOF
}

rth_guide_print_config() {
  local cfg
  cfg="$(rth_guide_cfg_path)"
  cat <<EOF
# rth guide config

Path: \`${cfg}\`
Override: \`RTH_CONFIG=/path/to/hosts.conf\` or \`rth --config PATH …\`

Minimal fields:
\`\`\`bash
RTH_ENVS="mac,win,ubuntu"

mac_kind="local"
mac_shell="bash"

win_kind="ssh"
win_host="192.168.x.x"
win_user="WindowsUser"
win_port="22"
win_shell="cmd"

ubuntu_kind="wsl"
ubuntu_host="192.168.x.x"
ubuntu_user="WindowsUser"
ubuntu_port="22"
ubuntu_distro="Ubuntu"
ubuntu_shell="bash"
\`\`\`

Example in package: \`\$RTH_ROOT/config/hosts.example.conf\`
After edit: \`rth doctor\`
EOF
}

rth_guide_print_agent() {
  cat <<'EOF'
# rth guide agent

## Mission
Help the user get `rth doctor` all-green, then run install/feature checks with `run`/`matrix`.

## Preferred command order
1. `rth guide --json` — load structured steps
2. `rth setup --non-interactive` — if no config/key
3. Read/edit `~/.config/rth/hosts.conf` (ask user for Windows IP + username if unknown)
4. Give user **paste-ready** PowerShell from `rth guide windows` for OpenSSH + pubkey
5. `rth doctor` — iterate until green
6. Daily: `rth matrix -- '…'` / `rth run -e win -- '…'`

## Contracts
| exit | meaning |
|------|---------|
| 0 | all ok |
| 2 | partial (some envs fail) |
| 3 | all fail / unreachable |
| 1 | usage/config |

stdout = remote data; stderr = rth diagnostics; prefer `--json` when parsing.

## Do not
- Realtime TTY sync
- Auto-disable Windows firewall without user consent
- Commit private keys
- Assume win_host from example (192.168.1.20 is placeholder)
EOF
}

# JSON playbook for agents
rth_guide_json() {
  local topic="${1:-setup}"
  local cfg pub
  cfg="$(rth_guide_cfg_path)"
  pub="$(rth_guide_pubkey)"

  printf '{'
  printf '"tool":"rth",'
  printf '"version":"%s",' "$(json_escape "${RTH_VERSION:-0.1.0}")"
  printf '"topic":"%s",' "$(json_escape "$topic")"
  printf '"config_path":"%s",' "$(json_escape "$cfg")"
  printf '"pubkey":"%s",' "$(json_escape "$pub")"
  printf '"agent_instructions":['
  printf '"Execute steps in order; stop on failure and report.",'
  printf '"Ask user only for Windows Admin actions and unknown IP/username.",'
  printf '"Use BatchMode SSH; never hang on password prompts.",'
  printf '"After green doctor, use run/matrix for install and feature loops."'
  printf '],'
  printf '"steps":['

  local cfg_j
  cfg_j="$(json_escape "$cfg")"

  case "$topic" in
    setup|lab|"")
      printf '%s' \
"{\"id\":1,\"title\":\"Install rth on controller\",\"where\":\"mac\",\"commands\":[\"curl -fsSL https://raw.githubusercontent.com/quangdang46/remote_test_helper/main/install.sh | bash -s -- --easy-mode --verify\"],\"verify\":\"rth --version\",\"user_action\":null}," \
"{\"id\":2,\"title\":\"Bootstrap config and SSH key\",\"where\":\"mac\",\"commands\":[\"rth setup --non-interactive\"],\"verify\":\"test -f hosts.conf\",\"user_action\":null}," \
"{\"id\":3,\"title\":\"Fill Windows host and user in hosts.conf\",\"where\":\"mac\",\"commands\":[\"edit hosts.conf\"],\"config_path\":\"${cfg_j}\",\"verify\":\"win_host and win_user set\",\"user_action\":\"Provide Windows LAN IP and username if unknown\"}," \
"{\"id\":4,\"title\":\"Enable OpenSSH Server\",\"where\":\"windows\",\"commands\":[\"Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0\",\"Start-Service sshd\",\"Set-Service -Name sshd -StartupType Automatic\"],\"verify\":\"Get-Service sshd\",\"user_action\":\"Run Admin PowerShell on Windows\"}," \
"{\"id\":5,\"title\":\"Install controller public key on Windows\",\"where\":\"windows\",\"commands\":[\"rth guide windows\",\"paste pubkey into authorized_keys or administrators_authorized_keys\"],\"verify\":\"ssh BatchMode echo ok\",\"user_action\":\"Paste pubkey; use Admin path if in Administrators group\"}," \
"{\"id\":6,\"title\":\"Ensure WSL distro running\",\"where\":\"windows\",\"commands\":[\"wsl -l -v\",\"wsl -e true\"],\"verify\":\"wsl -e uname -a\",\"user_action\":null}," \
"{\"id\":7,\"title\":\"Doctor all envs\",\"where\":\"mac\",\"commands\":[\"rth doctor\"],\"verify\":\"exit 0\",\"user_action\":null}," \
"{\"id\":8,\"title\":\"Smoke matrix\",\"where\":\"mac\",\"commands\":[\"rth matrix -- 'echo rth-ok'\"],\"verify\":\"exit 0\",\"user_action\":null}"
      ;;
    windows)
      printf '%s' \
"{\"id\":1,\"title\":\"OpenSSH Server\",\"where\":\"windows\",\"commands\":[\"Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0\",\"Start-Service sshd\",\"Set-Service -Name sshd -StartupType Automatic\"],\"verify\":\"Get-Service sshd\",\"user_action\":\"Admin PowerShell\"}," \
"{\"id\":2,\"title\":\"authorized_keys\",\"where\":\"windows\",\"commands\":[\"normal: USERPROFILE/.ssh/authorized_keys\",\"admin: C:/ProgramData/ssh/administrators_authorized_keys + icacls\"],\"verify\":\"BatchMode ssh from controller\",\"user_action\":\"Paste pubkey + fix ACL\"}"
      ;;
    wsl)
      printf '%s' \
"{\"id\":1,\"title\":\"List and wake WSL\",\"where\":\"windows\",\"commands\":[\"wsl -l -v\",\"wsl -e true\"],\"verify\":\"wsl -e uname -a\",\"user_action\":null}," \
"{\"id\":2,\"title\":\"Match ubuntu_distro in hosts.conf\",\"where\":\"mac\",\"commands\":[\"grep ubuntu_distro ~/.config/rth/hosts.conf\"],\"verify\":\"rth run -e ubuntu -- uname -a\",\"user_action\":null}"
      ;;
    config)
      printf '%s' \
"{\"id\":1,\"title\":\"Edit hosts.conf\",\"where\":\"mac\",\"commands\":[\"edit hosts.conf\"],\"config_path\":\"${cfg_j}\",\"verify\":\"rth status\",\"user_action\":\"Set win_host, win_user, ubuntu_*\"}"
      ;;
    agent)
      printf '%s' \
"{\"id\":1,\"title\":\"Load guide\",\"where\":\"mac\",\"commands\":[\"rth guide --json\"],\"verify\":null,\"user_action\":null}," \
"{\"id\":2,\"title\":\"Follow setup steps\",\"where\":\"mac\",\"commands\":[\"rth guide --json setup\"],\"verify\":\"rth doctor\",\"user_action\":null}"
      ;;
    *)
      printf '{"id":0,"title":"unknown topic","where":"either","commands":["rth guide"],"verify":null,"user_action":"Use topic setup|windows|wsl|config|agent"}'
      ;;
  esac

  printf '],'
  printf '"next_commands":["rth doctor","rth matrix -- '"'"'echo rth-ok'"'"'","rth run -e win -- '"'"'ver'"'"'"]'
  printf '}\n'
}

rth_cmd_guide() {
  local topic="setup"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        cat <<'EOF'
Usage: rth guide [topic] [--json]

Topics:
  setup    Full lab bring-up playbook (default) — for AI agents helping users
  windows  OpenSSH + authorized_keys paste-ready
  wsl      Ubuntu WSL hop
  config   hosts.conf fields
  agent    How agents should drive rth

Flags:
  --json   Structured steps + pubkey + agent_instructions (preferred for agents)

Examples:
  rth guide
  rth guide windows
  rth guide --json
  rth guide --json windows
EOF
        return 0
        ;;
      --json)
        # allow --json before or after topic; already may be set globally
        RTH_JSON=1
        shift
        ;;
      setup|lab|windows|win|wsl|ubuntu|config|agent)
        topic="$1"
        [[ "$topic" == "lab" ]] && topic="setup"
        [[ "$topic" == "win" ]] && topic="windows"
        [[ "$topic" == "ubuntu" ]] && topic="wsl"
        shift
        ;;
      *)
        rth_die "guide: unknown arg $1 (try: rth guide --help)"
        ;;
    esac
  done

  if [[ "$RTH_JSON" == "1" ]]; then
    rth_guide_json "$topic"
    return 0
  fi

  case "$topic" in
    setup) rth_guide_print_setup ;;
    windows) rth_guide_print_windows ;;
    wsl) rth_guide_print_wsl ;;
    config) rth_guide_print_config ;;
    agent) rth_guide_print_agent ;;
    *) rth_die "guide: unknown topic $topic" ;;
  esac
}
