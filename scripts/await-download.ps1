#requires -Version 5.1
<#
  await-download.ps1 - completion guard for BROWSER downloads.

  The download.php path (run.ps1) writes through curl and is synchronous, so it
  knows exactly when a file is complete. Browser downloads are not: the file is
  written to a .crdownload/.part, renamed on completion, and - if the browser is
  set to ask - parked behind a Save dialog that no amount of waiting will clear.

  This distinguishes the four real cases:

      COMPLETE      finished file, correct extension, appeared after -Since
      COMPLETE-TMP  browser partial stopped growing and already holds a valid
                    archive header (ampf / PK) - finished, just never renamed
      STALLED       partial exists and is NOT growing -> Save dialog is blocking
      NONE          nothing appeared

  Exit codes: COMPLETE/COMPLETE-TMP = 0, NONE = 1, STALLED = 2.

  Usage:
      scripts\await-download.ps1 -TimeoutSeconds 90
      scripts\await-download.ps1 -Since 2026-11-18T17:20:00 -Expect 'Thing'
#>

[CmdletBinding()]
param(
    [string]$Config,
    [string]$DownloadDir,
    [int]$TimeoutSeconds = 90,
    [string]$Since,             # ISO timestamp; defaults to 5 minutes ago
    [string]$Expect = '',       # filename substring that must appear
    [string[]]$Kinds
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg = Get-M4LConfig -Config $Config -Quiet
if (-not $DownloadDir) { $DownloadDir = $cfg.downloadsDir }

if (-not (Test-Path -LiteralPath $DownloadDir)) {
    Write-Output "NONE"
    Write-Output "  download folder does not exist: $DownloadDir"
    exit 1
}

$since = if ($Since) { [datetime]$Since } else { (Get-Date).AddMinutes(-5) }
$kindList = if ($Kinds) { $Kinds } else { @('.zip', '.amxd', '.alp', '.rar', '.7z', '.gz', '.maxpat') }

$result = Wait-M4LDownload -DownloadDir $DownloadDir -TimeoutSeconds $TimeoutSeconds -Since $since -Kinds $kindList -Expect $Expect

switch ($result.State) {
    'COMPLETE' {
        Write-Output 'COMPLETE'
        Write-Output ("  file : {0}" -f $result.File)
        Write-Output ("  size : {0} KB" -f [math]::Round($result.Size / 1KB))
        exit 0
    }
    'COMPLETE-TMP' {
        Write-Output 'COMPLETE-TMP'
        Write-Output ("  file : {0}" -f $result.File)
        Write-Output ("  size : {0} KB (settled, valid archive header, browser never renamed it)" -f [math]::Round($result.Size / 1KB))
        exit 0
    }
    'STALLED' {
        Write-Output 'STALLED'
        Write-Output ("  file : {0}" -f $result.File)
        Write-Output ("  size : {0} KB (not changing)" -f [math]::Round($result.Size / 1KB))
        Write-Output '  -> A Save/Open dialog is probably blocking the download.'
        Write-Output '  -> A human has to click Save, or the browser must be set to download'
        Write-Output '     automatically. Do not assume the file arrived.'
        exit 2
    }
    default {
        Write-Output 'NONE'
        Write-Output ("  no completed download and no partial in {0} within {1}s" -f $DownloadDir, $TimeoutSeconds)
        exit 1
    }
}
