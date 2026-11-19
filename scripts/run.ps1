#requires -Version 5.1
<#
  run.ps1 - the download worker.

  One worker at a time. It walks queue.json in order, POSTs each device to
  maxforlive.com/download.php, validates the response by magic bytes, and
  persists queue + pacing state after EVERY item so a kill or a reboot loses
  at most one device.

  Why curl and not Invoke-WebRequest: maxforlive.com sits behind Cloudflare,
  and the .NET HTTP stack's TLS fingerprint gets a flat 403 while curl.exe on
  the same machine, same headers, succeeds. Use curl.

  Why the pacing dance: bursting triggers HTTP 429 whose body is only
  "error code: 1015". Every later request then fails the same way, and a short
  body looks exactly like "File not found" - which silently produces false
  negatives ("the author removed it") for devices that are actually fine.
  The delay therefore only ever converges, never resets per run, and it is
  stored in state.json.

  Usage:
      scripts\run.ps1
      scripts\run.ps1 -MaxRuntimeMinutes 120 -Limit 40
      scripts\run.ps1 -Install            # download and place into the library
      scripts\run.ps1 -RetryErrors        # put error items back into pending
#>

[CmdletBinding()]
param(
    [string]$Config,
    [int]$MaxRuntimeMinutes = 0,     # 0 = use config.json
    [double]$StartDelay = 0,         # override the learned delay for this run
    [int]$Limit = 0,                 # stop after N items, 0 = until queue empty
    [switch]$Install,
    [switch]$RetryErrors,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg   = Get-M4LConfig -Config $Config
$paths = Get-M4LPaths -Config $cfg
$curl  = Get-CurlPath -Config $cfg
$ua    = $cfg.http.userAgent
$jar   = $paths.cookieJar
$tmp   = Join-Path $paths.workDir '_dl.tmp'

function Write-Log([string]$m) {
    Write-M4LLog -Message $m -LogFile $paths.runLog
    if (-not $Quiet) { Write-Host $m }
}

if (-not (Test-Path -LiteralPath $paths.queueFile)) {
    Write-Host "No queue at $($paths.queueFile). Run scripts\build-queue.ps1 first."
    exit 1
}

if ($RetryErrors) {
    $q = Read-JsonList -Path $paths.queueFile
    $changed = 0
    foreach ($i in $q) {
        if ($i.Status -in @('error', 'throttled') -and [int]$i.Attempts -lt 6) {
            $i.Status = 'pending'; $changed++
        }
    }
    [void](Write-JsonList -Path $paths.queueFile -Items $q)
    Write-Host "Re-queued $changed error items."
}

$state = Get-M4LState -Config $cfg -Path $paths.stateFile
if ($StartDelay -gt 0) { $state.delaySeconds = [Math]::Max([double]$cfg.pacing.minDelay, [Math]::Min([double]$cfg.pacing.maxDelay, $StartDelay)) }
$state.startedAt = (Get-Date -Format 'o')
Write-JsonObject -Path $paths.stateFile -Object $state

$runtime = if ($MaxRuntimeMinutes -gt 0) { $MaxRuntimeMinutes } else { [int]$cfg.pacing.maxRuntimeMinutes }
$deadline = (Get-Date).AddMinutes($runtime)

Write-Log "=== run start | delay=$([Math]::Round($state.delaySeconds,1))s runtime=${runtime}min install=$($Install.IsPresent) ==="

$done = 0
while ((Get-Date) -lt $deadline) {

    # Re-read every iteration: idempotent, crash safe, and a human can edit or
    # reorder queue.json while the worker is running.
    $queue = Read-JsonList -Path $paths.queueFile
    $pending = @($queue | Where-Object { $_.Status -eq 'pending' })
    if ($pending.Count -eq 0) { Write-Log 'queue empty - done'; break }
    if ($Limit -gt 0 -and $done -ge $Limit) { Write-Log "limit of $Limit items reached"; break }

    $item = @($pending | Select-Object -First 1)[0]
    $page = "https://maxforlive.com/library/device/$($item.Id)/"

    # ---- request ---------------------------------------------------------- #
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    & $curl -sS -L -A $ua -c $jar -b $jar -e $page --max-time $cfg.http.requestTimeoutSeconds `
        --data "id=$($item.Id)&submit=Download+Device" -o $tmp "https://maxforlive.com/download.php" 2>$null | Out-Null

    $item.Attempts = [int]$item.Attempts + 1
    $outcome = 'error'
    $note = ''

    $sig = [pscustomobject]@{ Kind = 'none'; Size = 0; Header = '' }
    if (Test-Path -LiteralPath $tmp) { $sig = Get-FileSignature -Path $tmp }

    if ($sig.Kind -in @('ampf', 'zip')) {
        # ---- valid payload ------------------------------------------------ #
        $ext = if ($sig.Kind -eq 'zip') { 'zip' } else { 'amxd' }
        $final = Join-Path $paths.downloads ("{0} [{1}].{2}" -f (ConvertTo-SafeName $item.Name), $item.Id, $ext)
        Move-Item -LiteralPath $tmp -Destination $final -Force
        $item.Status = 'downloaded'
        $item.Kind = $ext
        $item.File = $final
        $item.Note = ''
        $outcome = 'ok'
        Write-Log ("OK      id={0} {1} ({2} KB)" -f $item.Id, $item.Name, [math]::Round($sig.Size / 1KB))

        if ($Install) {
            # Child process: install-m4l.ps1 calls exit, and an in-process exit
            # would kill this worker instead of just returning a code.
            $res = Invoke-M4LScript -ScriptName 'install-m4l.ps1' -Arguments @('-Path', $final, '-Name', $item.Name, '-Config', [string]$Config)
            $code = $res.ExitCode
            if ($code -eq 0) {
                $item.Status = 'installed'
                $item.Note = (@($res.Output | Where-Object { $_ -match '^INSTALLED-' }) -join ' ')
            }
            elseif ($code -eq 4) { $item.Status = 'manual'; $item.Note = 'alp pack - drag into Live' }
            else {
                $item.Status = 'error'
                $item.Note = "install exit $code"
                foreach ($line in @($res.Output | Select-Object -First 4)) { Write-Log "        $line" }
            }
            Write-Log ("INSTALL id={0} -> {1} (exit {2})" -f $item.Id, $item.Status, $code)
        }
    }
    elseif ($sig.Kind -eq 'gz') {
        # Some authors upload a bare .gz of the .amxd.
        $final = Join-Path $paths.downloads ("{0} [{1}].amxd.gz" -f (ConvertTo-SafeName $item.Name), $item.Id)
        Move-Item -LiteralPath $tmp -Destination $final -Force
        $item.Status = 'downloaded'; $item.Kind = 'gz'; $item.File = $final
        $item.Note = 'gzip - extract before installing'
        $outcome = 'ok'
        Write-Log "OK      id=$($item.Id) (gzip) - extract before installing"
    }
    else {
        # ---- error body --------------------------------------------------- #
        $text = ''
        if (Test-Path -LiteralPath $tmp) {
            if ($sig.Size -lt 2048) { $text = ([System.IO.File]::ReadAllText($tmp)).Trim() }
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        $kind = Test-M4LResponseBody -Text $text

        switch ($kind) {
            'throttled' {
                $outcome = 'throttled'
                $item.Status = 'pending'          # retried in this same run
                $item.Note = "throttled x$($item.Attempts)"
            }
            'notfound' {
                # A real answer from the server: the file is gone / gated.
                $outcome = 'ok'
                $item.Status = 'gated'
                $item.Note = 'file not found on maxforlive.com (removed, or hosted on a store front)'
                Write-Log "GATED   id=$($item.Id) $($item.Name)"
            }
            default {
                $outcome = 'error'
                $item.Status = 'error'
                $item.Note = if ($text) { "$($sig.Size)B: " + $text.Substring(0, [Math]::Min(160, $text.Length)) } else { "no response ($($sig.Size)B)" }
                Write-Log "ERROR   id=$($item.Id) $($item.Note)"
            }
        }
    }

    $wait = Update-M4LPacing -State $state -Outcome $outcome -Config $cfg

    # ---- persist (crash safety) ------------------------------------------ #
    $fresh = Read-JsonList -Path $paths.queueFile
    $updated = New-Object System.Collections.ArrayList
    foreach ($f in $fresh) {
        if ([string]$f.Id -eq [string]$item.Id) {
            $f.Status   = $item.Status
            $f.Attempts = $item.Attempts
            $f.Kind     = $item.Kind
            $f.File     = $item.File
            $f.Note     = $item.Note
            [void]$updated.Add($f)
        } else {
            [void]$updated.Add($f)
        }
    }
    [void](Write-JsonList -Path $paths.queueFile -Items @($updated))
    Write-JsonObject -Path $paths.stateFile -Object $state

    $done++
    if ($outcome -eq 'throttled') {
        Write-Log "THROTTLE id=$($item.Id) -> delay now $([Math]::Round($state.delaySeconds,1))s, retrying in $([Math]::Round($wait,1))s"
    }

    # Do not sleep after the final item of the run.
    $queueNow = Read-JsonList -Path $paths.queueFile
    if (@($queueNow | Where-Object { $_.Status -eq 'pending' }).Count -gt 0) {
        Start-M4LWait -Seconds $wait
    }
}

$q = Read-JsonList -Path $paths.queueFile
$summary = @{}
foreach ($s in @('downloaded', 'installed', 'have', 'gated', 'error', 'manual', 'pending')) {
    $summary[$s] = @($q | Where-Object { $_.Status -eq $s }).Count
}
Write-Log ("=== run end | downloaded={0} installed={1} gated={2} error={3} pending={4} | delay={5:N1}s throttles={6} ===" -f `
    $summary['downloaded'], $summary['installed'], $summary['gated'], $summary['error'], $summary['pending'], [double]$state.delaySeconds, $state.throttleEvents)
