# rth Windows installer v2 — safe for:  irm URL | iex
# Does NOT call exit (exit closes the whole PowerShell window under iex).
#
#   irm "https://raw.githubusercontent.com/quangdang46/remote_test_helper/main/install.ps1" | iex
#
# Env (optional):
#   $env:RTH_BRANCH = "main"
#   $env:RTH_VERIFY = "1"
#   $env:RTH_FORCE_GITBASH = "1"   # skip WSL
#   $env:RTH_FORCE_WSL = "1"
#   $env:RTH_NO_EASY = "1"         # do not edit User PATH
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

$DoVerify    = ($env:RTH_VERIFY -eq "1")
$DoUninstall = ($env:RTH_UNINSTALL -eq "1")
$DoEasy      = -not ($env:RTH_NO_EASY -eq "1")
$ForceGitBash = ($env:RTH_FORCE_GITBASH -eq "1")
$ForceWsl     = ($env:RTH_FORCE_WSL -eq "1")

function Rth-Info([string]$m) { Write-Host "[rth] $m" }
function Rth-Ok([string]$m)   { Write-Host "[rth] OK $m" -ForegroundColor Green }
function Rth-Err([string]$m)  { Write-Host "[rth] ERROR $m" -ForegroundColor Red }

# Never use exit under irm|iex — it kills the host window (looks like a crash).
function Rth-Fail([string]$m) {
  Rth-Err $m
  throw $m
}

function Rth-Download([string]$Url, [string]$OutFile) {
  $dir = Split-Path -Parent $OutFile
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  # WebClient is more reliable than IWR on PS 5.1
  $wc = New-Object System.Net.WebClient
  try {
    $wc.DownloadFile($Url, $OutFile)
  } finally {
    $wc.Dispose()
  }
  if (-not (Test-Path $OutFile)) {
    Rth-Fail "download failed: $Url"
  }
}

function Rth-HasGitBash {
  $paths = @(
    (Join-Path $env:ProgramFiles "Git\bin\bash.exe")
  )
  $pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
  if ($pf86) {
    $paths += (Join-Path $pf86 "Git\bin\bash.exe")
  }
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
  # -l is less likely to hang than launching a distro
  try {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $out = & wsl.exe -l -q 2>$null
    $ErrorActionPreference = $old
    if ($LASTEXITCODE -ne 0) { return $false }
    if (-not $out) { return $false }
    return $true
  } catch {
    return $false
  }
}

function Rth-ToUnixPath([string]$win) {
  if ($win -match "^([A-Za-z]):\\(.*)$") {
    $d = $Matches[1].ToLower()
    $r = $Matches[2].Replace("\", "/")
    return "/$d/$r"
  }
  return $win.Replace("\", "/")
}

function Rth-InstallWsl {
  Rth-Info "Installing inside WSL (curl install.sh)..."
  $url = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/install.sh"
  $flags = "--easy-mode"
  if ($DoVerify) { $flags = "$flags --verify" }
  $cmd = "curl -fsSL $url | bash -s -- $flags"
  Rth-Info "wsl -e bash -lc <$cmd>"
  & wsl.exe -e bash -lc $cmd
  if ($LASTEXITCODE -ne 0) {
    Rth-Fail "WSL install failed (exit $LASTEXITCODE). Set `$env:RTH_FORCE_GITBASH=1 and retry, or fix WSL."
  }
  Rth-Ok "installed in WSL"
  Rth-Info "Open Ubuntu/WSL terminal, then: rth setup"
  Rth-Info "Or: wsl -e rth --help"
}

function Rth-InstallGitBash([string]$BashExe) {
  Rth-Info "Git Bash: $BashExe"
  Rth-Info "Dest=$Dest Share=$Share"

  New-Item -ItemType Directory -Force -Path $Dest  | Out-Null
  New-Item -ItemType Directory -Force -Path $Share | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Share "bin") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Share "lib") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $Share "config") | Out-Null

  $base = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
  $tmp = Join-Path $env:TEMP ("rth-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null

  try {
    $rels = @(
      "bin/rth",
      "lib/common.sh",
      "lib/ssh.sh",
      "lib/matrix.sh",
      "lib/setup.sh",
      "lib/guide.sh",
      "config/hosts.example.conf"
    )
    foreach ($rel in $rels) {
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
    # LF-only bash wrapper (single-quoted PS strings — no $@ expansion bugs)
    $nl = [char]10
    $runBody = '#!/usr/bin/env bash' + $nl +
      'set -euo pipefail' + $nl +
      ('export RTH_ROOT="' + $shareUnix + '"') + $nl +
      'exec bash "$RTH_ROOT/bin/rth" "$@"' + $nl
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($runSh, $runBody, $utf8NoBom)

    $cmdPath = Join-Path $Dest "rth.cmd"
    $cmdLines = @(
      "@echo off",
      "setlocal",
      "`"$BashExe`" `"$runSh`" %*"
    )
    [System.IO.File]::WriteAllText($cmdPath, ($cmdLines -join "`r`n") + "`r`n")

    if ($DoEasy) {
      $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
      if (-not $userPath) { $userPath = "" }
      $hit = $false
      foreach ($part in $userPath.Split(";")) {
        if ($part -and ($part.TrimEnd("\") -ieq $Dest.TrimEnd("\"))) { $hit = $true }
      }
      if (-not $hit) {
        if ($userPath) {
          [Environment]::SetEnvironmentVariable("Path", "$Dest;$userPath", "User")
        } else {
          [Environment]::SetEnvironmentVariable("Path", $Dest, "User")
        }
        $env:Path = "$Dest;" + $env:Path
        Rth-Info "PATH updated (open a NEW terminal for 'rth')"
      }
    }

    if ($DoVerify) {
      Rth-Info "verify..."
      & $BashExe $runSh "--version"
      if ($LASTEXITCODE -ne 0) { Rth-Fail "verify failed" }
    }

    Rth-Ok "installed $cmdPath"
    Rth-Info "Next: rth setup"
    Rth-Info "Then: rth doctor"
  } finally {
    if (Test-Path $tmp) {
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
    }
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
  if ($ForceWsl) {
    $useWsl = $true
  } elseif (-not $ForceGitBash) {
    $useWsl = Rth-HasWsl
  }

  if ($useWsl) {
    Rth-InstallWsl
    return
  }

  Rth-Info "Using Git Bash path (WSL skipped or unavailable)..."
  $bash = Rth-HasGitBash
  if ($bash) {
    Rth-InstallGitBash $bash
    return
  }

  Rth-Fail @"
Need WSL or Git Bash.

  WSL:  wsl --install   (reboot, open Ubuntu once)
  Git:  https://git-scm.com/download/win

Then:
  irm "https://raw.githubusercontent.com/$Owner/$Repo/main/install.ps1" | iex

Force Git Bash even if WSL exists:
  `$env:RTH_FORCE_GITBASH = "1"
  irm "https://raw.githubusercontent.com/$Owner/$Repo/main/install.ps1" | iex
"@
} catch {
  Rth-Err $_.Exception.Message
  # do not rethrow if you want a quiet end; rethrow keeps $Error populated
  # return without exit so the PowerShell window stays open
  return
}
