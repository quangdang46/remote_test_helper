# install.ps1 — remote_test_helper (rth) for Windows
# irm https://raw.githubusercontent.com/quangdang46/remote_test_helper/main/install.ps1 | iex
param(
    [string]$Dest = "",
    [switch]$EasyMode,
    [switch]$Verify,
    [switch]$Uninstall,
    [string]$Branch = "main",
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"
$Owner = "quangdang46"
$Repo = "remote_test_helper"
$Binary = "rth"

function Write-Info($msg) { Write-Host "[rth] $msg" }
function Write-Ok($msg)   { Write-Host "✓ $msg" -ForegroundColor Green }
function Die($msg)        { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

if ($Uninstall) {
    $share = Join-Path $env:USERPROFILE ".local\share\rth"
    $dest = if ($Dest) { $Dest } else { Join-Path $env:USERPROFILE ".local\bin" }
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $dest "rth")
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $dest "rth.cmd")
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $share
    Write-Ok "Uninstalled rth"
    exit 0
}

# Prefer WSL install (bash CLI)
$wsl = Get-Command wsl -ErrorAction SilentlyContinue
if ($wsl) {
    Write-Info "WSL detected — installing rth inside default WSL distro..."
    $ref = if ($Version) { $Version } else { $Branch }
    $url = "https://raw.githubusercontent.com/$Owner/$Repo/$ref/install.sh"
    $flags = "--easy-mode"
    if ($Verify) { $flags = "$flags --verify" }
    $bash = @"
set -euo pipefail
curl -fsSL '$url' | bash -s -- $flags
"@
    wsl -e bash -lc $bash
    if ($LASTEXITCODE -ne 0) { Die "WSL install failed (exit $LASTEXITCODE)" }
    Write-Ok "Installed via WSL. Open WSL and run: rth setup"
    Write-Info "From PowerShell: wsl -e rth --help"
    exit 0
}

# Git Bash fallback
$bashCandidates = @(
    "C:\Program Files\Git\bin\bash.exe",
    "C:\Program Files (x86)\Git\bin\bash.exe"
)
$bashExe = $bashCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $bashExe) {
    Die "Neither WSL nor Git Bash found. Install WSL (Ubuntu) or Git for Windows, then re-run."
}

Write-Info "Git Bash found — installing user-local rth..."
if (-not $Dest) { $Dest = Join-Path $env:USERPROFILE ".local\bin" }
$Share = Join-Path $env:USERPROFILE ".local\share\rth"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
New-Item -ItemType Directory -Force -Path $Share | Out-Null

$ref = if ($Version) { $Version } else { $Branch }
$base = "https://raw.githubusercontent.com/$Owner/$Repo/$ref"
$tmp = Join-Path $env:TEMP "rth-install-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
    $files = @(
        @{ Rel = "bin/rth"; Out = "bin\rth" },
        @{ Rel = "lib/common.sh"; Out = "lib\common.sh" },
        @{ Rel = "lib/ssh.sh"; Out = "lib\ssh.sh" },
        @{ Rel = "lib/matrix.sh"; Out = "lib\matrix.sh" },
        @{ Rel = "lib/setup.sh"; Out = "lib\setup.sh" },
        @{ Rel = "config/hosts.example.conf"; Out = "config\hosts.example.conf" }
    )
    foreach ($f in $files) {
        $outPath = Join-Path $tmp $f.Out
        New-Item -ItemType Directory -Force -Path (Split-Path $outPath) | Out-Null
        Invoke-WebRequest -Uri "$base/$($f.Rel)" -OutFile $outPath -UseBasicParsing
    }

    $shareUnix = ($Share -replace '\\', '/') -replace '^([A-Za-z]):', '/$1'
    # Map C:\Users\... -> /c/Users for Git Bash — use cygpath if available
    $shareForBash = & $bashExe -lc "cygpath -u '$Share'" 2>$null
    if (-not $shareForBash) {
        # rough fallback C:\ -> /c/
        $drive = $Share.Substring(0, 1).ToLower()
        $shareForBash = "/$drive" + ($Share.Substring(2) -replace '\\', '/')
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $Share "bin") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Share "lib") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Share "config") | Out-Null
    Copy-Item (Join-Path $tmp "bin\rth") (Join-Path $Share "bin\rth") -Force
    Copy-Item (Join-Path $tmp "lib\*") (Join-Path $Share "lib") -Force
    if (Test-Path (Join-Path $tmp "config")) {
        Copy-Item (Join-Path $tmp "config\*") (Join-Path $Share "config") -Force -ErrorAction SilentlyContinue
    }

    # Wrapper scripts
    $rthCmd = @"
@echo off
"$bashExe" -lc "export RTH_ROOT='$shareForBash'; exec bash '\$RTH_ROOT/bin/rth' %*"
"@
    # Simpler cmd shim
    $shim = @"
@echo off
setlocal
set "RTH_ROOT=$Share"
"$bashExe" "%RTH_ROOT%\bin\rth" %*
"@
    Set-Content -Path (Join-Path $Dest "rth.cmd") -Value $shim -Encoding ASCII

    if ($EasyMode) {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$Dest*") {
            [Environment]::SetEnvironmentVariable("Path", "$Dest;$userPath", "User")
            Write-Info "Added $Dest to User PATH — open a new terminal"
        }
    }

    if ($Verify) {
        & $bashExe -lc "export RTH_ROOT='$shareForBash'; bash '\$RTH_ROOT/bin/rth' --version"
    }

    Write-Ok "rth installed → $(Join-Path $Dest 'rth.cmd')"
    Write-Info "Next: rth setup   then   rth doctor"
}
finally {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
}
