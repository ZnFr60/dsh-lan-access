<#
.SYNOPSIS
  One-click installer for the dsh-lan-access plugin (DeepSeek Harness LAN access).
.DESCRIPTION
  Checks prerequisites (dsh, pnpm), installs the plugin into the web profile,
  restarts dsh web, verifies the result, and optionally adds a LAN-only
  firewall rule. Run from an elevated PowerShell for the firewall option.
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

# ---------- 1. check dsh ----------
Write-Host "[1/6] checking dsh ..."
$dsh = Get-Command dsh -ErrorAction SilentlyContinue
if (-not $dsh) { Write-Error "dsh not found. Install DeepSeek Harness (dsh) first."; exit 1 }
Write-Host "      dsh -> $($dsh.Source)"

# ---------- 2. check / install pnpm ----------
Write-Host "[2/6] checking pnpm ..."
function Test-Pnpm {
  if (Get-Command pnpm -ErrorAction SilentlyContinue) { return $true }
  if (Get-Command corepack -ErrorAction SilentlyContinue) {
    Write-Host "      enabling pnpm via corepack ..."
    try { corepack enable | Out-Null } catch { }
    return [bool](Get-Command pnpm -ErrorAction SilentlyContinue)
  }
  return $false
}
if (-not (Test-Pnpm)) {
  Write-Host "      pnpm missing; trying npm install -g pnpm ..."
  $npm = Get-Command npm -ErrorAction SilentlyContinue
  if (-not $npm) { Write-Error "npm not found. Install pnpm manually: https://pnpm.io/installation"; exit 1 }
  npm install -g pnpm
  if ($LASTEXITCODE -ne 0) { Write-Error "pnpm install failed. Install pnpm manually and retry."; exit 1 }
}
Write-Host "      pnpm: $((Get-Command pnpm).Source)"

# ---------- 3. pick source ----------
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
dsh plugin --profile web add $spec
if ($LASTEXITCODE -ne 0) { Write-Error "plugin install failed (exit $LASTEXITCODE)"; exit 1 }

# ---------- 4. restart dsh web ----------
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

# ---------- 5. verify ----------
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

# ---------- 6. firewall (optional, admin) ----------
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
