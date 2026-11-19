#requires -Version 5.1
<#
  monitor.ps1 - one-glance status for a running (or finished) harvest.

  Reads only files, never the network: safe to run as often as you like while a
  worker is going.

  Usage:
      scripts\monitor.ps1
      scripts\monitor.ps1 -Tail 30
#>

[CmdletBinding()]
param(
    [string]$Config,
    [int]$Tail = 12
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg   = Get-M4LConfig -Config $Config -Quiet
$paths = Get-M4LPaths -Config $cfg

if (-not (Test-Path -LiteralPath $paths.queueFile)) {
    Write-Host 'No queue yet. Run scripts\list-devices.ps1 then scripts\build-queue.ps1.'
    exit 0
}

$queue = Read-JsonList -Path $paths.queueFile
$state = Read-JsonObject -Path $paths.stateFile

$total   = $queue.Count
$counts  = @{}
foreach ($s in @('downloaded', 'installed', 'have', 'gated', 'error', 'manual', 'pending')) {
    $counts[$s] = @($queue | Where-Object { $_.Status -eq $s }).Count
}
$resolved = $counts['downloaded'] + $counts['installed'] + $counts['gated'] + $counts['error'] + $counts['manual']
$pct = if ($total -gt 0) { 100.0 * $resolved / $total } else { 0 }

Write-Host ''
Write-Host '==================== M4L HARVEST ===================='
Write-Host (" Library : {0}" -f $(if ($cfg.userLibrary) { $cfg.userLibrary } else { '(not configured)' }))
Write-Host (" Queue   : {0}" -f $paths.queueFile)
Write-Host (" Progress: {0} / {1} ({2:N1}%)" -f $resolved, $total, $pct)
Write-Host ''
foreach ($s in @('downloaded', 'installed', 'have', 'gated', 'error', 'manual', 'pending')) {
    Write-Host ("   {0,-11}: {1}" -f $s, $counts[$s])
}

if ($state) {
    Write-Host ''
    Write-Host ' --- adaptive pacing ---'
    Write-Host ("   current delay   : {0:N1}s  (min {1:N1}s / max {2:N1}s)" -f [double]$state.delaySeconds, [double]$state.minDelay, [double]$state.maxDelay)
    Write-Host ("   throttle events : {0}" -f $state.throttleEvents)
    Write-Host ("   success streak  : {0}" -f $state.consecutiveOk)
    Write-Host ("   last activity   : {0}" -f $state.lastRun)
    if ($counts['pending'] -gt 0) {
        $eta = [math]::Round(($counts['pending'] * [double]$state.delaySeconds) / 60, 1)
        Write-Host ("   ETA             : ~{0} min for the remaining {1}" -f $eta, $counts['pending'])
    }
}

# --- is a worker actually alive? ------------------------------------------- #
Write-Host ''
Write-Host ' --- running? ---'
$procs = @()
try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
               Where-Object { $_.CommandLine -and $_.CommandLine -match 'run\.ps1' -and ($_.CommandLine -match 'maxforlive' -or $_.CommandLine -match 'harvest') })
} catch {
    # Win32_Process is Windows-only; fall back to Get-Process (PS7 exposes CommandLine)
    $procs = @(Get-Process -Name powershell, pwsh -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -and $_.CommandLine -match 'run\.ps1' -and ($_.CommandLine -match 'maxforlive' -or $_.CommandLine -match 'harvest') })
}
if ($procs.Count -gt 0) {
    Write-Host ("   RUNNING (pid {0})" -f (($procs | ForEach-Object { $_.ProcessId }) -join ','))
} else {
    Write-Host '   no harvest worker process found'
}

# --- recent log ------------------------------------------------------------ #
Write-Host ''
Write-Host (" --- last {0} log lines ---" -f $Tail)
if (Test-Path -LiteralPath $paths.runLog) {
    Get-Content -LiteralPath $paths.runLog -Tail $Tail | ForEach-Object { Write-Host "   $_" }
} else {
    Write-Host '   (no log yet)'
}

# --- payloads -------------------------------------------------------------- #
$files = @(Get-ChildItem -LiteralPath $paths.downloads -File -ErrorAction SilentlyContinue)
if ($files.Count -gt 0) {
    Write-Host ''
    Write-Host ' --- newest payloads ---'
    $files | Sort-Object LastWriteTime -Descending | Select-Object -First 8 |
        ForEach-Object { Write-Host ("   {0,-70} {1,8} KB" -f $_.Name, [math]::Round($_.Length / 1KB)) }
}

# --- anything stuck in an error state -------------------------------------- #
$errors = @($queue | Where-Object { $_.Status -eq 'error' })
if ($errors.Count -gt 0) {
    Write-Host ''
    Write-Host ' --- first errors ---'
    $errors | Select-Object -First 6 | ForEach-Object { Write-Host ("   {0}  {1}  {2}" -f $_.Id, $_.Name, $_.Note) }
    Write-Host '   (scripts\run.ps1 -RetryErrors puts them back to pending)'
}
Write-Host ''
