# Windows OpenSSH for rth

## Enable OpenSSH Server (Admin PowerShell)

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
```

Confirm listening:

```powershell
Get-Service sshd
```

## Key-based auth

On the controller (Mac/WSL), copy your public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

### Normal Windows user

Put the key in:

```text
C:\Users\<You>\.ssh\authorized_keys
```

```powershell
New-Item -ItemType Directory -Force -Path $env:USERPROFILE\.ssh
# paste pubkey into authorized_keys (one line)
icacls $env:USERPROFILE\.ssh\authorized_keys /inheritance:r
icacls $env:USERPROFILE\.ssh\authorized_keys /grant:r "$env:USERNAME:(R)"
```

### User in Administrators group (common footgun)

OpenSSH may **ignore** `C:\Users\…\.ssh\authorized_keys` for Administrators.

Use instead:

```text
C:\ProgramData\ssh\administrators_authorized_keys
```

ACL (Admin PowerShell):

```powershell
# After creating the file with your pubkey:
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "SYSTEM:(F)"
icacls C:\ProgramData\ssh\administrators_authorized_keys /grant "Administrators:(F)"
Restart-Service sshd
```

## Test from Mac

```bash
ssh -o BatchMode=yes YourUser@WINDOWS_IP "cmd /c echo ok"
rth doctor
rth run -e win -- "echo rth-ok"
```

## Firewall

Optional feature install usually opens port 22. If not:

```powershell
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```
