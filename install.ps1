# install.ps1 — remote_test_helper (rth) for Windows
#
# README one-liner (irm|iex safe — no param() block):
#   irm "https://raw.githubusercontent.com/quangdang46/remote_test_helper/main/install.ps1" | iex
#
# Optional env before irm|iex:
#   $env:RTH_VERIFY = "1"
#   $env:RTH_BRANCH = "main"
#   $env:RTH_NO_EASY = "1"     # skip PATH update
#   $env:RTH_UNINSTALL = "1"
#
# Or save + run:
#   irm .../install.ps1 -OutFile $env:TEMP\rth-install.ps1
#   powershell -ExecutionPolicy Bypass -File $env:TEMP\rth-install.ps1

$ErrorActionPreference = "Stop"

try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$Owner  = "quangdang46"
$Repo   = "remote_test_helper"
$Branch = if ($env:RTH_BRANCH) { $env:RTH_BRANCH } else { "main" }
$Dest   = if ($env:RTH_DEST) { $env:RTH_DEST } else { Join-Path $env:USERPROFILE ".local\bin" }
$Share  = if ($env:RTH_SHARE) { $env:RTH_SHARE } else { Join-Path $env:USERPROFILE ".local\share\rth" }
$Verify    = ($env:RTH_VERIFY -eq "1") -or ($env:RTH_VERIFY -eq "true")
$Uninstall = ($env:RTH_UNINSTALL -eq "1") -or ($env:RTH_UNINSTALL -eq "true")
$EasyMode  = -not (($env:RTH_NO_EASY -eq "1") -or ($env:RTH_NO_EASY -eq "true"))
if ($env:RTH_EASY_MODE -eq "0" -or $env:RTH_EASY_MODE -eq "false") { $EasyMode = $false }

function Write-Info([string]$msg) { Write-Host "[rth] $msg" }
function Write-Ok([string]$msg)   { Write-Host "[rth] OK: $msg" -ForegroundColor Green }
function Die([string]$msg) {
    Write-Host "[rth] ERROR: $msg" -ForegroundColor Red
    exit 1
}

function Test-WslReady {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { return $false }
    try {
        $p = Start-Process -FilePath "wsl.exe" -ArgumentList @("-e", "true") `
            -Wait -PassThru -NoNewWindow -WindowStyle Hidden
        return ($null -ne $p -and $p.ExitCode -eq 0)
    } catch {
        return $false
    }
}

function Install-ViaWsl {
    param([string]$Ref)
    Write-Info "WSL ready - installing rth inside WSL..."
    $url = "https://raw.githubusercontent.com/$Owner/$Repo/$Ref/install.sh"
    $flags = "--easy-mode"
    if ($Verify) { $flags = "$flags --verify" }
    $inner = "curl -fsSL '$url' | bash -s -- $flags"
    Write-Info "wsl -e bash -lc `"$inner`""
    $p = Start-Process -FilePath "wsl.exe" `
        -ArgumentList @("-e", "bash", "-lc", $inner) `
        -Wait -PassThru -NoNewWindow
    if ($null -eq $p -or $p.ExitCode -ne 0) {
        $code = if ($p) { $p.ExitCode } else { "null" }
        Die "WSL install failed (exit $code). Fix WSL or install Git for Windows."
    }
    Write-Ok "Installed via WSL"
    Write-Info "Open WSL shell: rth setup"
    Write-Info "From PowerShell: wsl -e rth --help"
}

function Find-GitBash {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles "Git\bin\bash.exe"))
    }
    $pf86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if ($pf86) {
        $candidates.Add((Join-Path $pf86 "Git\bin\bash.exe"))
    }
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA "Programs\Git\bin\bash.exe"))
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Convert-ToGitBashPath([string]$WinPath) {
    # C:\Users\foo -> /c/Users/foo
    if ($WinPath -match '^([A-Za-z]):\\(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2] -replace '\\', '/'
        return "/$drive/$rest"
    }
    return ($WinPath -replace '\\', '/')
}

function Install-ViaGitBash {
    param([string]$BashExe, [string]$Ref)

    Write-Info "Git Bash: $BashExe"
    Write-Info "Install share: $Share"
    New-Item -ItemType Directory -Force -Path $Dest  | Out-Null
    New-Item -ItemType Directory -Force -Path $Share | Out-Null

    $base = "https://raw.githubusercontent.com/$Owner/$Repo/$Ref"
    $tmp = Join-Path $env:TEMP ("rth-install-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    try {
        $files = @(
            "bin/rth",
            "lib/common.sh",
            "lib/ssh.sh",
            "lib/matrix.sh",
            "lib/setup.sh",
            "lib/guide.sh",
            "config/hosts.example.conf"
        )
        foreach ($rel in $files) {
            $outPath = Join-Path $tmp ($rel -replace "/", [IO.Path]::DirectorySeparatorChar)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
            Write-Info "GET $rel"
            Invoke-WebRequest -Uri "$base/$rel" -OutFile $outPath -UseBasicParsing
        }

        New-Item -ItemType Directory -Force -Path (Join-Path $Share "bin")    | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $Share "lib")    | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $Share "config") | Out-Null
        Copy-Item (Join-Path $tmp "bin\rth") (Join-Path $Share "bin\rth") -Force
        Copy-Item (Join-Path $tmp "lib\*")   (Join-Path $Share "lib") -Force
        if (Test-Path (Join-Path $tmp "config")) {
            Copy-Item (Join-Path $tmp "config\*") (Join-Path $Share "config") -Force -ErrorAction SilentlyContinue
        }

        $shareUnix = Convert-ToGitBashPath $Share

        # Unix wrapper invoked by rth.cmd
        $runSh = Join-Path $Share "rth-run.sh"
        $runShBody = @"
#!/usr/bin/env bash
set -euo pipefail
export RTH_ROOT="$shareUnix"
exec bash "`$RTH_ROOT/bin/rth" "`$@"
"@
        # Write with LF for bash
        [IO.File]::WriteAllText($runSh, ($runShBody -replace "`r`n", "`n"))

        # rth.cmd — ASCII only, no fancy quotes
        $cmdPath = Join-Path $Dest "rth.cmd"
        $cmdBody = @"
@echo off
setlocal
"$BashExe" "$runSh" %*
"@
        Set-Content -Path $cmdPath -Value $cmdBody -Encoding ASCII

        if ($EasyMode) {
            $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
            if (-not $userPath) { $userPath = "" }
            $parts = $userPath -split ';' | Where-Object { $_ -and ($_.Trim() -ne "") }
            if ($parts -notcontains $Dest) {
                $newPath = if ($userPath) { "$Dest;$userPath" } else { "$Dest" }
                [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
                $env:Path = "$Dest;$env:Path"
                Write-Info "Added to User PATH: $Dest (open a new terminal)"
            }
        }

        if ($Verify) {
            Write-Info "Verify rth --version ..."
            $p = Start-Process -FilePath $BashExe -ArgumentList @($runSh, "--version") `
                -Wait -PassThru -NoNewWindow
            if ($null -eq $p -or $p.ExitCode -ne 0) {
                Die "verify failed"
            }
        }

        Write-Ok "rth installed -> $cmdPath"
        Write-Info "Next: rth setup"
        Write-Info "Then: rth doctor"
    } finally {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp
    }
}

try {
    if ($Uninstall) {
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Dest "rth")
        Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Dest "rth.cmd")
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Share
        Write-Ok "Uninstalled rth"
        exit 0
    }

    Write-Info "remote_test_helper installer (branch=$Branch)"

    if (Test-WslReady) {
        Install-ViaWsl -Ref $Branch
        exit 0
    }
    Write-Info "WSL not ready - trying Git Bash..."

    $bashExe = Find-GitBash
    if ($bashExe) {
        Install-ViaGitBash -BashExe $bashExe -Ref $Branch
        exit 0
    }

    Die @"
Neither working WSL nor Git Bash found.

Install one of:
  1) WSL:  wsl --install   (then reboot, open Ubuntu once)
  2) Git for Windows: https://git-scm.com/download/win

Re-run:
  irm "https://raw.githubusercontent.com/$Owner/$Repo/main/install.ps1" | iex
"@
} catch {
    Write-Host "[rth] ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }
    exit 1
}
