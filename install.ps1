# rth Windows installer v5 — irm|iex safe (no exit; no param block)
# After WSL install ALWAYS writes %USERPROFILE%\.local\bin\rth.cmd + User PATH.
# Also installs agent skill into ~/.agents/skills/rth and symlinks providers.
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
#   $env:RTH_SKIP_SKILL = "1"   # or RTH_NO_SKILL=1
#   $env:RTH_SKILL_DEST = "C:\Users\you\.agents\skills"

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

$SkillName = "rth"
$SkillDest = Join-Path $env:USERPROFILE ".agents\skills"
if ($env:RTH_SKILL_DEST) { $SkillDest = $env:RTH_SKILL_DEST }

$DoVerify     = ($env:RTH_VERIFY -eq "1")
$DoUninstall  = ($env:RTH_UNINSTALL -eq "1")
$DoEasy       = -not ($env:RTH_NO_EASY -eq "1")
$ForceGitBash = ($env:RTH_FORCE_GITBASH -eq "1")
$ForceWsl     = ($env:RTH_FORCE_WSL -eq "1")
$SkipSkill    = ($env:RTH_SKIP_SKILL -eq "1") -or ($env:RTH_NO_SKILL -eq "1")

function Rth-Info([string]$m) { Write-Host "[rth] $m" }
function Rth-Ok([string]$m)   { Write-Host "[rth] OK $m" -ForegroundColor Green }
function Rth-Err([string]$m)  { Write-Host "[rth] ERROR $m" -ForegroundColor Red }
function Rth-Fail([string]$m) { Rth-Err $m; throw $m }

function Rth-SkillIsOurs([string]$File) {
  if (-not (Test-Path -LiteralPath $File)) { return $false }
  try {
    $head = Get-Content -LiteralPath $File -TotalCount 8 -ErrorAction SilentlyContinue
    return [bool]($head -match ("^name:\s*" + [regex]::Escape($SkillName) + "\s*$"))
  } catch { return $false }
}

function Rth-SkillProviderRoots {
  $roots = @(
    (Join-Path $env:USERPROFILE ".claude\skills"),
    (Join-Path $env:USERPROFILE ".codex\skills"),
    (Join-Path $env:USERPROFILE ".cursor\skills"),
    (Join-Path $env:USERPROFILE ".opencode\skills"),
    (Join-Path $env:USERPROFILE ".config\opencode\skills"),
    (Join-Path $env:USERPROFILE ".gemini\skills"),
    (Join-Path $env:USERPROFILE ".config\gemini\skills")
  )
  if ($env:CLAUDE_SKILLS_DIR) { $roots = @($env:CLAUDE_SKILLS_DIR) + $roots }
  if ($env:CODEX_HOME) {
    $roots = @((Join-Path $env:CODEX_HOME "skills")) + $roots
  }
  return $roots | Select-Object -Unique
}

function Rth-LinkSkillToProviders([string]$Canonical) {
  if (-not (Test-Path -LiteralPath $Canonical)) { return }
  foreach ($root in Rth-SkillProviderRoots) {
    if (-not $root) { continue }
    if ($root -ieq $SkillDest) { continue }
    $parent = Split-Path -Parent $root
    if (-not (Test-Path -LiteralPath $parent)) { continue }
    try { New-Item -ItemType Directory -Force -Path $root | Out-Null } catch { continue }
    $link = Join-Path $root $SkillName

    if (Test-Path -LiteralPath $link) {
      $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
      if ($item -and $item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        try {
          # Refresh junction/symlink to canonical
          cmd /c "rmdir `"$link`"" 2>$null | Out-Null
        } catch {}
      } elseif (Test-Path -LiteralPath (Join-Path $link "SKILL.md")) {
        if (Rth-SkillIsOurs (Join-Path $link "SKILL.md")) {
          Remove-Item -Recurse -Force -LiteralPath $link -ErrorAction SilentlyContinue
        } else {
          Rth-Info "skill at $link exists (not ours) — leave alone"
          continue
        }
      } else {
        Rth-Info "skill at $link exists (not ours) — leave alone"
        continue
      }
    }

    $linked = $false
    try {
      # Directory junction works without admin on Windows.
      $null = New-Item -ItemType Junction -Path $link -Target $Canonical -Force -ErrorAction Stop
      $linked = $true
      Rth-Info "skill link → $link"
    } catch {
      try {
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $Canonical -Force -ErrorAction Stop
        $linked = $true
        Rth-Info "skill link → $link"
      } catch {
        $linked = $false
      }
    }
    if (-not $linked) {
      try {
        New-Item -ItemType Directory -Force -Path $link | Out-Null
        Copy-Item -LiteralPath (Join-Path $Canonical "SKILL.md") -Destination (Join-Path $link "SKILL.md") -Force
        Rth-Info "skill copy → $link (link unavailable)"
      } catch {}
    }
  }
}

function Rth-UninstallAgentSkill {
  $skillDir = Join-Path $SkillDest $SkillName
  $skillFile = Join-Path $skillDir "SKILL.md"
  if (Test-Path -LiteralPath $skillFile) {
    if (Rth-SkillIsOurs $skillFile) {
      Remove-Item -Force -LiteralPath $skillFile -ErrorAction SilentlyContinue
      Remove-Item -Force -LiteralPath $skillDir -ErrorAction SilentlyContinue
      Rth-Info "removed agent skill $skillDir"
    }
  } elseif (Test-Path -LiteralPath $skillDir) {
    $item = Get-Item -LiteralPath $skillDir -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      try { cmd /c "rmdir `"$skillDir`"" 2>$null | Out-Null } catch {
        Remove-Item -Force -LiteralPath $skillDir -ErrorAction SilentlyContinue
      }
    }
  }

  foreach ($root in Rth-SkillProviderRoots) {
    $link = Join-Path $root $SkillName
    if (-not (Test-Path -LiteralPath $link)) { continue }
    $item = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      try { cmd /c "rmdir `"$link`"" 2>$null | Out-Null } catch {
        Remove-Item -Force -LiteralPath $link -ErrorAction SilentlyContinue
      }
    } elseif (Test-Path -LiteralPath (Join-Path $link "SKILL.md")) {
      if (Rth-SkillIsOurs (Join-Path $link "SKILL.md")) {
        Remove-Item -Recurse -Force -LiteralPath $link -ErrorAction SilentlyContinue
      }
    }
  }
}

function Rth-InstallAgentSkill {
  if ($SkipSkill) {
    Rth-Info "Skipping agent skill (RTH_SKIP_SKILL/RTH_NO_SKILL)"
    return
  }

  $skillDir = Join-Path $SkillDest $SkillName
  $skillFile = Join-Path $skillDir "SKILL.md"
  $shareSkillDir = Join-Path $Share "skills\$SkillName"
  $shareSkill = Join-Path $shareSkillDir "SKILL.md"

  if ((Test-Path -LiteralPath $skillFile) -and -not (Rth-SkillIsOurs $skillFile)) {
    Rth-Info "agent skill at $skillFile looks user-edited — leaving it alone"
    return
  }

  try {
    New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
    New-Item -ItemType Directory -Force -Path $shareSkillDir | Out-Null
  } catch {
    Rth-Info "could not create $skillDir — skipping agent skill install"
    return
  }

  $src = $null
  if (Test-Path -LiteralPath $shareSkill) {
    $src = $shareSkill
  }

  if ($src) {
    Copy-Item -LiteralPath $src -Destination $skillFile -Force
  } else {
    $url = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/.agents/skills/$SkillName/SKILL.md"
    $tmp = "$skillFile.tmp.$PID"
    try {
      Rth-Download $url $tmp
      Move-Item -LiteralPath $tmp -Destination $skillFile -Force
      Copy-Item -LiteralPath $skillFile -Destination $shareSkill -Force -ErrorAction SilentlyContinue
    } catch {
      Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
      Rth-Info "could not download agent skill from $url (continuing)"
      return
    }
  }

  if (Test-Path -LiteralPath $skillFile) {
    Rth-Ok "agent skill installed → $skillFile"
    Rth-LinkSkillToProviders $skillDir
  }
}

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

  # Avoid UTF-16 nulls from some wsl stdout quirks: ask bash for path cleanly
  $raw = & wsl.exe -e bash -lc 'printf %s "$HOME/.local/bin/rth"'
  $resolved = (-join ($raw | ForEach-Object { "$_" })).Trim()
  $resolved = $resolved -replace "`0", ""
  if (-not $resolved) { Rth-Fail "could not resolve HOME/.local/bin/rth in WSL" }

  & wsl.exe -e test -f $resolved 2>$null
  if ($LASTEXITCODE -ne 0) {
    Rth-Fail "WSL file missing: $resolved (install.sh may have failed)"
  }

  # rth is a bash script -> wsl -e bash /path/to/rth args...
  $text = "@echo off`r`nrem rth Windows shim -> WSL`r`nwsl.exe -e bash $resolved %*`r`n"
  [System.IO.File]::WriteAllText($cmdPath, $text)
  if (-not (Test-Path -LiteralPath $cmdPath)) {
    Rth-Fail "failed to write $cmdPath"
  }
  Rth-Ok "Windows shim written: $cmdPath"
  Rth-Info "  -> wsl.exe -e bash $resolved %*"
  Rth-AddUserPath $Dest
  return $cmdPath
}

function Rth-InstallWsl {
  Rth-Info "Installing inside WSL (curl install.sh)..."
  $url = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch/install.sh"
  $flags = "--easy-mode"
  if ($DoVerify) { $flags = "$flags --verify" }
  if ($SkipSkill) { $flags = "$flags --skip-skill" }
  $cmd = "curl -fsSL $url | bash -s -- $flags"
  Rth-Info "wsl -e bash -lc: $cmd"
  & wsl.exe -e bash -lc $cmd
  if ($LASTEXITCODE -ne 0) {
    Rth-Fail "WSL install failed (exit $LASTEXITCODE). Try: `$env:RTH_FORCE_GITBASH='1'; irm ... | iex"
  }
  Rth-Ok "WSL binary at ~/.local/bin/rth"

  Rth-Info "Creating Windows rth.cmd (so PowerShell finds rth)..."
  $shim = Rth-WriteWslShim

  # Also place skill on the Windows profile so native Windows agents see it.
  Rth-InstallAgentSkill

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
  New-Item -ItemType Directory -Force -Path (Join-Path $Share "skills\$SkillName") | Out-Null

  $base = "https://raw.githubusercontent.com/$Owner/$Repo/$Branch"
  $tmp = Join-Path $env:TEMP ("rth-" + [Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    foreach ($rel in @(
      "bin/rth","lib/common.sh","lib/ssh.sh","lib/matrix.sh",
      "lib/setup.sh","lib/guide.sh","config/hosts.example.conf",
      ".agents/skills/rth/SKILL.md"
    )) {
      $out = Join-Path $tmp ($rel.Replace("/", "\"))
      Rth-Info "GET $rel"
      try { Rth-Download "$base/$rel" $out } catch {
        if ($rel -like "*.agents/*") {
          Rth-Info "skill download soft-fail (continuing): $rel"
        } else {
          throw
        }
      }
    }
    Copy-Item (Join-Path $tmp "bin\rth") (Join-Path $Share "bin\rth") -Force
    Copy-Item (Join-Path $tmp "lib\*") (Join-Path $Share "lib") -Force
    if (Test-Path (Join-Path $tmp "config")) {
      Copy-Item (Join-Path $tmp "config\*") (Join-Path $Share "config") -Force -ErrorAction SilentlyContinue
    }
    $tmpSkill = Join-Path $tmp ".agents\skills\rth\SKILL.md"
    if (Test-Path -LiteralPath $tmpSkill) {
      Copy-Item $tmpSkill (Join-Path $Share "skills\$SkillName\SKILL.md") -Force
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
    Rth-InstallAgentSkill
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
    Rth-UninstallAgentSkill
    Rth-Ok "uninstalled"
    return
  }

  Rth-Info "install.ps1 v5 (branch=$Branch) — skill + Windows rth.cmd after WSL"

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
