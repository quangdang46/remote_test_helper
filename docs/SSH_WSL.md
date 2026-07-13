# Ubuntu WSL for rth (v1 hop)

v1 does **not** require SSH inside WSL. rth connects to **Windows OpenSSH**, then:

```text
ssh user@windows 'wsl -d Ubuntu -- bash -lc "COMMAND"'
```

## Requirements

1. Windows OpenSSH works (`rth run -e win -- echo ok`)
2. WSL distro installed and listed:

```powershell
wsl -l -v
```

3. `ubuntu_distro` in `~/.config/rth/hosts.conf` matches the name exactly (often `Ubuntu`).

## Wake WSL

If WSL is stopped:

```powershell
wsl -e true
```

## Config snippet

```bash
ubuntu_kind="wsl"
ubuntu_host="192.168.1.20"    # same as win_host
ubuntu_user="YourWindowsUser" # Windows user for SSH hop
ubuntu_port="22"
ubuntu_distro="Ubuntu"
ubuntu_shell="bash"
```

## Direct SSH into WSL (phase 2, optional)

Not automated in v1. Outline:

1. Inside WSL: `sudo apt install openssh-server`, set `Port 2222`
2. Windows `netsh interface portproxy` LAN → WSL IP
3. Firewall open 2222
4. Refresh portproxy after WSL IP changes (reboot)

Then set `ubuntu_kind="ssh"` and `ubuntu_port="2222"`.
