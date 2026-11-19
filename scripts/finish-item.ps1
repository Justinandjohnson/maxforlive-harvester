#requires -Version 5.1
<#
  finish-item.ps1 - one full browser-download cycle for ONE device.

  Waits for the browser to finish dropping a file, validates the magic bytes,
  renames a stuck .crdownload if it is really complete, then installs with
  install-m4l.ps1. Built for the Gumroad flow, where the "download" is a click
  in a page rather than an HTTP response you can read.

  Exit codes:
      0 instal|complete   (the payload is now in the library, or needs a manual drag)
      2 STALLED  - Save dialog blocking; nothing was installed
      1 NONE     - no download appeared
      3 invalid payload
      4 .alp - manual drag required (still a success for the harvest)

  Usage:
      scripts\finish-item.ps1 -Name 'Thing' -Since 2026-11-18T17:20:00 -Expect 'Thing'
#>

[CmdletBinding()]
param(
    [string]$Config,
    [Parameter(Mandatory = $true)][string]$Name,
    [string]$Since,
    [int]$TimeoutSeconds = 90,
    [string]$Expect = '',
    [string]$DownloadDir,
    [switch]$NoInstall,
    [switch]$KeepSourceTrees
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg = Get-M4LConfig -Config $Config
$paths = Get-M4LPaths -Config $cfg
if (-not $DownloadDir) { $DownloadDir = $cfg.downloadsDir }

$since = if ($Since) { [datetime]$Since } else { (Get-Date).AddMinutes(-5) }
$safe  = ConvertTo-SafeName $Name

Write-Output ("WATCHING: {0} (since {1:HH:mm:ss}, timeout {2}s)" -f $DownloadDir, $since, $TimeoutSeconds)

$result = Wait-M4LDownload -DownloadDir $DownloadDir -TimeoutSeconds $TimeoutSeconds -Since $since -Expect $Expect

switch ($result.State) {
    'NONE' {
        Write-Output 'RESULT: NONE'
        Write-Output '  no file arrived. Check whether the download button actually responded.'
        exit 1
    }
    'STALLED' {
        Write-Output 'RESULT: STALLED'
        Write-Output ("  {0} is not growing - a Save dialog is blocking it." -f $result.File)
        Write-Output '  Ask the operator to click Save (or enable automatic downloads), then re-run this script.'
        exit 2
    }
}

$path = $result.File
$ext  = [System.IO.Path]::GetExtension($path).ToLower()

# A browser can leave a finished file with a temporary name.
if ($ext -in @('.tmp', '.part', '.download', '.crdownload', '.partial')) {
    $sig = Get-FileSignature -Path $path
    $realExt = switch ($sig.Kind) { 'ampf' { '.amxd' } 'zip' { '.zip' } 'gz' { '.gz' } default { '.bin' } }
    $renamed = Join-Path $DownloadDir ("$safe$realExt")
    Copy-Item -LiteralPath $path -Destination $renamed -Force
    Write-Output ("RENAMED: {0} -> {1}" -f $path, $renamed)
    $path = $renamed
    $ext  = $realExt
}

$sig = Get-FileSignature -Path $path
Write-Output ("FILE: {0}" -f $path)
Write-Output ("SIZE: {0} KB" -f [math]::Round($sig.Size / 1KB))
Write-Output ("MAGIC: {0} ({1})" -f $sig.Kind, $sig.Header)

if ($sig.Kind -notin @('ampf', 'zip') -and $ext -ne '.alp') {
    Write-Output 'RESULT: INVALID'
    Write-Output '  the payload is neither a Max device ("ampf") nor a zip ("PK").'
    Write-Output '  Most likely the download was an HTML error page. Nothing installed.'
    exit 3
}

if ($NoInstall) {
    Write-Output 'RESULT: DOWNLOADED (install skipped)'
    exit 0
}

$installArgs = @('-Path', $path, '-Name', $Name, '-Config', [string]$Config)
if ($KeepSourceTrees) { $installArgs += '-KeepSourceTrees' }
$res = Invoke-M4LScript -ScriptName 'install-m4l.ps1' -Arguments $installArgs
foreach ($line in $res.Output) { Write-Output $line }
$code = $res.ExitCode

if ($code -eq 0) {
    Write-Output 'RESULT: INSTALLED'
    $status = Get-UserLibraryStatus -UserLibrary $cfg.userLibrary
    if ($status.Ok) {
        $count = @(Get-ChildItem -LiteralPath $status.DevicesDir -Recurse -File -Filter '*.amxd' -ErrorAction SilentlyContinue).Count
        Write-Output ("LIBRARY-AMXD-COUNT: {0}" -f $count)
    }
    exit 0
}
if ($code -eq 4) {
    Write-Output 'RESULT: MANUAL (alp pack)'
    exit 4
}
Write-Output ("RESULT: INSTALL-FAILED (exit {0})" -f $code)
exit 3
