<#
.SYNOPSIS
  One-click installer for the dsh-lan-access plugin (DeepSeek Harness LAN access).
.DESCRIPTION
  Bootstraps missing PATH entries (node, npm, pnpm, dsh, git), then checks
  prerequisites, installs the plugin into the web profile, restarts dsh web,
  verifies, and optionally adds a LAN-only firewall rule.
  All PATH changes are temporary to this script process only - your permanent
  environment is never modified.
.PARAMETER Source
  Install source: github (default) | gitee | npm | link
.PARAMETER RepoDir
  Local repo path when -Source link
.PARAMETER NoRestart
  Skip restarting dsh web after install
.PARAMETER AddFirewallRule
  Add firewall rule "dsh-lan-3080" (TCP 3080, LocalSubnet). Needs admin.
.PARAMETER KeepConsole
  Keep the restarted dsh web attached to this console instead of hidden.
.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -Source gitee
.EXAMPLE
  .\install.ps1 -AddFirewallRule -Verbose
#>
[CmdletBinding()]
param(
  [ValidateSet("github", "gitee", "npm", "link")]
  [string]$Source = "github",
  [string]$RepoDir = "",
  [switch]$NoRestart,
  [switch]$AddFirewallRule,
  [switch]$KeepConsole
)

$ErrorActionPreference = "Stop"
$Port = 3080

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " dsh-lan-access auto-install (DeepSeek Harness)" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# ---------------------------------------------------------------
# 0. PATH bootstrap: find tools even if they are NOT on PATH.
#    Everything here is scoped to this process only.
# ---------------------------------------------------------------
function Add-PathIfExists {
  param([string[]]$Dirs)
  $added = 0
  foreach ($d in $Dirs) {
    if (-not $d) { continue }
    $full = [System.IO.Path]::GetFullPath($d.TrimEnd('\'))
    if ((Test-Path $full) -and ($env:Path -notlike "*$full*")) {
      $env:Path = "$full;$env:Path"
      $added++
      Write-Verbose "  PATH+ $full"
    }
  }
  return $added
}

# npm global bin (where dsh / pnpm shims live), pnpm home, nodejs installs, git
$bootstrapDirs = @(
  "$env:APPDATA\npm",                    # npm global bin: dsh, pnpm, npm shims
  "$env:LOCALAPPDATA\pnpm",              # pnpm global
  "$env:LOCALAPPDATA\Programs\nodejs",   # nodejs.org bundled installer
  "C:\Program Files\nodejs",             # system-wide nodejs
  "$env:ProgramFiles\nodejs",
  "$env:ProgramFiles(x86)\nodejs",
  "C:\Program Files\Git\cmd",            # git
  "C:\Program Files\Git\mingw64\bin",
  "$env:ProgramFiles\Git\cmd",
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
  # nvm-windows
  "$env:NVM_HOME",
  "$env:NVM_HOME\nodejs",
  "C:\nvm4w\nodejs",
  # scoop
  "$env:USERPROFILE\scoop\shims",
  # chocolatey
  "$env:ChocolateyInstall\bin"
)
$n = Add-PathIfExists $bootstrapDirs
if ($n -gt 0) { Write-Host "[0/6] PATH bootstrap: added $n candidate dir(s)" }

# If node/npm still missing, probe a few common node.exe paths directly and add their dirs
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  $nodeCandidates = @(
    "C:\Program Files\nodejs\node.exe",
    "$env:LOCALAPPDATA\Programs\nodejs\node.exe",
    "$env:ProgramFiles\nodejs\node.exe",
    "$env:NVM_HOME\nodejs\node.exe",
    "C:\nvm4w\nodejs\node.exe"
  )
  foreach ($p in $nodeCandidates) {
    if (Test-Path $p) {
      Add-PathIfExists @([System.IO.Path]::GetDirectoryName($p))
      break
    }
  }
}

# Last resort: bounded scan for node.exe in common roots (only if still missing).
# Depth-limited so it stays fast and never walks the whole disk.
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Write-Host "      node not found in common paths; scanning a few roots (bounded)..."
  $scanRoots = @("$env:ProgramFiles", "$env:LOCALAPPDATA", "$env:APPDATA")
  $foundNode = $null
  foreach ($root in $scanRoots) {
    if (-not $root -or -not (Test-Path $root)) { continue }
    try {
      $hit = Get-ChildItem -Path $root -Filter node.exe -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'nodejs|nvm|node' } | Select-Object -First 1
      if ($hit) { $foundNode = $hit.FullName; break }
    } catch { }
  }
  if ($foundNode) {
    Add-PathIfExists @([System.IO.Path]::GetDirectoryName($foundNode))
    Write-Host "      found node at: $foundNode"
  }
}

# ---------------------------------------------------------------
# 1. check dsh
# ---------------------------------------------------------------
Write-Host "[1/6] checking dsh ..."
$dsh = Get-Command dsh -ErrorAction SilentlyContinue
if (-not $dsh) {
  Write-Error @"
dsh not found. Install DeepSeek Harness first. If installed but not on PATH,
start the installer from a shell that has it, or add its bin directory to PATH.
Details: https://github.com/ZnFr60/dsh-lan-access
"@
  exit 1
}
Write-Host "      dsh -> $($dsh.Source)"

# ---------------------------------------------------------------
# 2. check / install pnpm
# ---------------------------------------------------------------
Write-Host "[2/6] checking pnpm ..."
function Test-Pnpm {
  if (Get-Command pnpm -ErrorAction SilentlyContinue) { return $true }
  $corepack = Get-Command corepack -ErrorAction SilentlyContinue
  if ($corepack) {
    Write-Host "      enabling pnpm via corepack ..."
    try { corepack enable | Out-Null } catch { }
    # corepack enable installs shims into the npm global bin dir; refresh PATH
    Add-PathIfExists @("$env:APPDATA\npm")
    return [bool](Get-Command pnpm -ErrorAction SilentlyContinue)
  }
  return $false
}
if (-not (Test-Pnpm)) {
  Write-Host "      pnpm missing; trying npm install -g pnpm ..."
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $npm) {
    Write-Error "npm/node not found. Please install Node.js (adds node, npm to PATH): https://nodejs.org/"
    exit 1
  }
  npm install -g pnpm
  if ($LASTEXITCODE -ne 0) { Write-Error "pnpm install failed. Install pnpm manually: https://pnpm.io/installation"; exit 1 }
  Add-PathIfExists @("$env:APPDATA\npm")
}
Write-Host "      pnpm: $((Get-Command pnpm).Source)"

# ---------------------------------------------------------------
# 3. pick source & install
# ---------------------------------------------------------------
Write-Host "[3/6] installing plugin (source=$Source) ..."
$spec = switch ($Source) {
  "github" { "github:ZnFr60/dsh-lan-access#main" }
  "gitee"  { "git+https://gitee.com/mnrf/dsh-lan-access.git" }
  "npm"    { "dsh-lan-access" }
  "link"   {
    if (-not $RepoDir -or -not (Test-Path $RepoDir)) { Write-Error "-Source link needs a valid -RepoDir"; exit 1 }
    "link:$RepoDir"
  }
}
Write-Host "      run: dsh plugin --profile web add $spec"
$pluginOut = dsh plugin --profile web add $spec 2>&1
if ($LASTEXITCODE -ne 0) {
  $outText = $pluginOut | Out-String
  if ($outText -match "UNEXPECTED_STORE|store location|reinstall your dependencies") {
    Write-Host ""
    Write-Host "[!] pnpm store version mismatch detected. Fix:" -ForegroundColor Yellow
    Write-Host "    In your profile dir run:  pnpm install" -ForegroundColor Yellow
    Write-Host "    Then re-run this script." -ForegroundColor Yellow
    Write-Host ""
  }
  Write-Error "plugin install failed (exit $LASTEXITCODE)"
  exit 1
}

# ---------------------------------------------------------------
# 4. restart dsh web
# ---------------------------------------------------------------
if ($NoRestart) {
  Write-Host "[4/6] skipped restart (-NoRestart). Run manually: dsh web --no-open"
} else {
  Write-Host "[4/6] restarting dsh web (port $Port) ..."
  try {
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
      ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
  } catch { Write-Warning "could not auto-stop old process (ignored): $($_.Exception.Message)" }
  Start-Sleep -Seconds 1
  $dshPath = $dsh.Source
  try {
    if ($KeepConsole) {
      & $dshPath web --no-open
    } else {
      if ($dshPath -like "*.ps1") { Start-Process pwsh -ArgumentList "-NoProfile","-File",$dshPath,"web","--no-open" -WindowStyle Hidden }
      elseif ($dshPath -like "*.cmd") { Start-Process cmd -ArgumentList "/c",$dshPath,"web","--no-open" -WindowStyle Hidden }
      else { Start-Process -FilePath $dshPath -ArgumentList "web","--no-open" -WindowStyle Hidden }
    }
    Start-Sleep -Seconds 3
    Write-Host "      dsh web started"
  } catch {
    Write-Warning "auto-restart failed; run manually: dsh web --no-open  ($($_.Exception.Message))"
  }
}

# ---------------------------------------------------------------
# 5. verify
# ---------------------------------------------------------------
Write-Host "[5/6] verifying plugin is active ..."
$cfg = dsh --profile web --dump-config 2>&1 | Out-String
$okHost = $cfg -match "host: 0\.0\.0\.0"
$okRow  = $cfg -match "lan-access"
Write-Host "      webserver.host == 0.0.0.0 : $(if($okHost){'OK'}else{'MISSING'})"
Write-Host "      lan-access row mounted      : $(if($okRow){'OK'}else{'MISSING'})"
$page = $null
try { $page = (Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:$Port/" -TimeoutSec 5).Content } catch { }
$okShim = $page -match "randomUUID" -and $page -match "getRandomValues"
Write-Host "      index.html randomUUID shim  : $(if($okShim){'OK'}else{'UNCHECKED (appears after restart)'})"

# ---------------------------------------------------------------
# 6. firewall (optional, admin)
# ---------------------------------------------------------------
if ($AddFirewallRule) {
  Write-Host "[6/6] adding firewall rule dsh-lan-3080 (LocalSubnet) ..."
  netsh advfirewall firewall add rule name="dsh-lan-3080" dir=in action=allow protocol=TCP localport=$Port remoteip=LocalSubnet enable=yes profile=any
}

Write-Host ""
Write-Host "================ DONE ================" -ForegroundColor Green
Write-Host "  local :  http://127.0.0.1:$Port"
Write-Host "  phone :  http://<your-lan-ipv4>:$Port   (same LAN/subnet)"
if (-not $okHost -or -not $okRow) {
  Write-Warning "  some checks failed. Confirm you installed into the web profile and restarted dsh web."
}
