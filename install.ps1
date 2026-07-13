# rth Windows installer v4 — irm|iex safe (no exit; no param block)
# After WSL install ALWAYS writes %USERPROFILE%\.local\bin\rth.cmd + User PATH.
#
# Cache-bust one-liner:
#   irm "https://raw.githubusercontent.com/quangdang46/remote_test_helper/main/install.ps1?$(Get-Random)" | iex
#
# Env:
#   $env:RTH_BRANCH = "main"
#   $env:RTH_VERIFY = "1"
#   $env:RTH_FORCE_GITBASH = "1"
#   $env:RTH_FORCE_WSL = "1"
#   $env:RTH_NO_EASY = "1"
#   $env:RTH_UNINSTALL = "1"

$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$Owner  = "quangdang46"
$Repo   = "remote_test_helper"
$Branch = "main"
if ($env:RTH_BRANCH) { $Branch = $env:RTH_BRANCH }

$Dest  = Join-Path $env:USERPROFILE ".local\bin"
$Share = Join-Path $env:USERPROFILE ".local\share\rth"
if ($env:RTH_DEST)  { $Dest  = $env:RTH_DEST }
if ($env:RTH_SHARE) { $Share = $env:RTH_SHARE }

$DoVerify     = ($env:RTH_VERIFY -eq "1")
$DoUninstall  = ($env:RTH_UNINSTALL -eq "1")
$DoEasy       = -not ($env:RTH_NO_EASY -eq "1")
$ForceGitBash = ($env:RTH_FORCE_GITBASH -eq "1")
$ForceWsl     = ($env:RTH_FORCE_WSL -eq "1")

function Rth-Info([string]$m) { Write-Host "[rth] $m" }
function Rth-Ok([string]$m)   { Write-Host "[rth] OK $m" -ForegroundColor Green }
function Rth-Err([string]$m)  { Write-Host "[rth] ERROR $m" -ForegroundColor Red }
function Rth-Fail([string]$m) { Rth-Err $m; throw $m }

function Rth-AddUserPath([string]$Dir) {
  if (-not $DoEasy) { return }
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $userPath) { $userPath = "" }
  $hit = $false
  foreach ($part in $userPath.Split(";")) {
    if ($part -and ($part.TrimEnd("\") -ieq $Dir.TrimEnd("\"))) { $hit = $true }
  }
  if (-not $hit) {
    if ($userPath) {
      [Environment]::SetEnvironmentVariable("Path", "$Dir;$userPath", "User")
    } else {
      [Environment]::SetEnvironmentVariable("Path", $Dir, "User")
    }
    Rth-Info "Added to User PATH: $Dir"
  }
  if ($env:Path -notlike "*$Dir*") {
    $env:Path = "$Dir;" + $env:Path
  }
}

function Rth-Download([string]$Url, [string]$OutFile) {
  $dir = Split-Path -Parent $OutFile
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $wc = New-Object System.Net.WebClient
  try { $wc.DownloadFile($Url, $OutFile) } finally { $wc.Dispose() }
  if (-not (Test-Path $OutFile)) { Rth-Fail "download failed: $Url" }
}

function Rth-FindGitBash {
  $paths = @()
  if ($env:ProgramFiles) {
    $paths += (Join-Path $env:ProgramFiles "Git\bin\bash.exe")
  }
  $pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
  if ($pf86) { $paths += (Join-Path $pf86 "Git\bin\bash.exe") }
  if ($env:LOCALAPPDATA) {
    $paths += (Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe")
  }
  foreach ($p in $paths) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  return $null
}

function Rth-HasWsl {
  if ($ForceGitBash) { return $false }
  if (-not (Get-Command "wsl.exe" -ErrorAction SilentlyContinue)) { return $false }
  try {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $null = & wsl.exe -l -q 2>$null
    $ErrorActionPreference = $old
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

function Rth-ToUnixPath([string]$win) {
  if ($win -match "^([A-Za-z]):\\(.*)$") {
    return ("/" + $Matches[1].ToLower() + "/" + $Matches[2].Replace("\", "/"))
  }
  return $win.Replace("\", "/")
}

function Rth-WriteWslShim {
  # Install puts rth only inside WSL. PowerShell needs a .cmd proxy.
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  $cmdPath = Join-Path $Dest "rth.cmd"

  $resolved = (& wsl.exe -e bash -lc "echo -n `$HOME/.local/bin/rth").Trim()
  if (-not $resolved) { Rth-Fail "could not resolve `$HOME/.local/bin/rth in WSL" }

  & wsl.exe -e test -f $resolved 2>$null
  if ($LASTEXITCODE -ne 0) {
    Rth-Fail "WSL file missing: $resolved (install.sh may have failed)"
  }

  # rth is a bash script -> wsl -e bash /path/to/rth args...
  $text = "@echo off`r`nrem rth Windows shim -> WSL`r`nwsl.exe -e bash $resolved %*`r`n"
  [System.IO.File]::WriteAllText($cmdPath, $text)
  Rth-Ok "Windows shim: $cmdPath"
  Rth-Info "  runs: wsl.exe -e bash $resolved"
  Rth-AddUserPath $Dest
  return $cmdPath
}

function Rth-InstallWsl {
  Rth-Info "Installing inside WSL (curl install.sh)..."
  $url = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/install.sh"
  $flags = "--easy-mode"
  if ($DoVerify) { $flags = "$flags --verify" }
  $cmd = "curl -fsSL $url | bash -s -- $flags"
  Rth-Info "wsl -e bash -lc: $cmd"
  & wsl.exe -e bash -lc $cmd
  if ($LASTEXITCODE -ne 0) {
    Rth-Fail "WSL install failed (exit $LASTEXITCODE). Try: `$env:RTH_FORCE_GITBASH='1'; irm ... | iex"
  }
  Rth-Ok "WSL binary at ~/.local/bin/rth"

  Rth-Info "Creating Windows rth.cmd (so PowerShell finds rth)..."
  $shim = Rth-WriteWslShim

  Rth-Info "Quick check: rth --version"
  try {
    & $shim --version
  } catch {
    Rth-Info "shim check soft-fail; run manually: wsl -e bash -lc 'rth --version'"
  }

  Rth-Ok "done — try: rth --version"
  Rth-Info "If not found, open a NEW PowerShell, or: `$env:Path = `"$Dest;`$env:Path`""
  Rth-Info "Next: rth setup"
}

function Rth-InstallGitBash([string]$BashExe) {
  Rth-Info "Git Bash install: $BashExe"
  New-Item -ItemType Directory -Force -Path $Dest  | Out-Null
  New-Item -ItemType Directory -Force -Path $Share | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Share "bin") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Share "lib") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Share "config") | Out-Null

  $base = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
  $tmp = Join-Path $env:TEMP ("rth-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    foreach ($rel in @(
      "bin/rth","lib/common.sh","lib/ssh.sh","lib/matrix.sh",
      "lib/setup.sh","lib/guide.sh","config/hosts.example.conf"
    )) {
      $out = Join-Path $tmp ($rel.Replace("/", "\"))
      Rth-Info "GET $rel"
      Rth-Download "$base/$rel" $out
    }
    Copy-Item (Join-Path $tmp "bin\rth") (Join-Path $Share "bin\rth") -Force
    Copy-Item (Join-Path $tmp "lib\*") (Join-Path $Share "lib") -Force
    if (Test-Path (Join-Path $tmp "config")) {
      Copy-Item (Join-Path $tmp "config\*") (Join-Path $Share "config") -Force -ErrorAction SilentlyContinue
    }

    $shareUnix = Rth-ToUnixPath $Share
    $runSh = Join-Path $Share "rth-run.sh"
    $nl = [char]10
    $runBody = '#!/usr/bin/env bash' + $nl +
      'set -euo pipefail' + $nl +
      ('export RTH_ROOT="' + $shareUnix + '"') + $nl +
      'exec bash "$RTH_ROOT/bin/rth" "$@"' + $nl
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($runSh, $runBody, $utf8)

    $cmdPath = Join-Path $Dest "rth.cmd"
    $cmdBody = "@echo off`r`n`"$BashExe`" `"$runSh`" %*`r`n"
    [System.IO.File]::WriteAllText($cmdPath, $cmdBody)

    Rth-AddUserPath $Dest
    if ($DoVerify) {
      & $BashExe $runSh "--version"
      if ($LASTEXITCODE -ne 0) { Rth-Fail "verify failed" }
    }
    Rth-Ok "installed $cmdPath"
    Rth-Info "Next: rth setup"
  } finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
  }
}

# ---- main ----
try {
  if ($DoUninstall) {
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Dest "rth")
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Dest "rth.cmd")
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Share
    Rth-Ok "uninstalled"
    return
  }

  Rth-Info "remote_test_helper Windows installer ($Branch)"

  $useWsl = $false
  if ($ForceWsl) { $useWsl = $true }
  elseif (-not $ForceGitBash) { $useWsl = Rth-HasWsl }

  if ($useWsl) {
    Rth-InstallWsl
    return
  }

  Rth-Info "WSL path skipped — trying Git Bash..."
  $bash = Rth-FindGitBash
  if ($bash) {
    Rth-InstallGitBash $bash
    return
  }

  Rth-Fail "Need WSL or Git for Windows. Install one, then re-run irm|iex."
} catch {
  Rth-Err $_.Exception.Message
  return
}
