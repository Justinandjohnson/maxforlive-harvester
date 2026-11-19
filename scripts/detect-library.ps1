#requires -Version 5.1
<#
  detect-library.ps1 - first-run setup.

  Finds the real User Library path by reading Ableton Live's own indexer log,
  then writes config.json next to this repo. This is deliberately NOT
  "~/Documents/Ableton/User Library": on Windows the Documents folder is very
  often redirected into OneDrive or another drive, and in that case Live
  indexes a different folder than the one a hard-coded path would write to.
  Installs then appear to succeed but never show up in the browser.

  Usage:
      scripts\detect-library.ps1
      scripts\detect-library.ps1 -List
      scripts\detect-library.ps1 -UserLibrary 'D:\Audio\Ableton\User Library' -Force
      scripts\detect-library.ps1 -LiveVersion '12.2.5' -Force
#>

[CmdletBinding()]
param(
    [string]$Config,
    [string]$UserLibrary,
    [string]$LiveVersion,
    [string]$BuyerEmail,
    [string]$Collection,
    [string]$DownloadsDir,
    [switch]$List,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

function Get-IndexerCandidates {
    <#
      Enumerates every Live version that has an Indexer.txt, newest log first.
      Ableton keeps one Preferences folder per installed version, so several
      can coexist after an upgrade.
    #>
    $roots = New-Object System.Collections.ArrayList

    if ($env:APPDATA) {
        [void]$roots.Add((Join-Path $env:APPDATA 'Ableton'))
    }
    $home_ = [Environment]::GetFolderPath('UserProfile')
    if ($IsMacOS -or -not $env:APPDATA) {
        [void]$roots.Add((Join-Path $home_ 'Library/Preferences/Ableton'))
    }
    # Best effort for Linux/Wine installs; harmless when absent.
    [void]$roots.Add((Join-Path $home_ '.local/share/Ableton'))

    $found = New-Object System.Collections.ArrayList
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $logs = @(Get-ChildItem -LiteralPath $root -Directory -Filter 'Live *' -ErrorAction SilentlyContinue |
                  ForEach-Object { Join-Path $_.FullName 'Preferences/Indexer.txt' } |
                  Where-Object { Test-Path -LiteralPath $_ })
        foreach ($log in $logs) {
            $info = Get-Item -LiteralPath $log
            $version = Split-Path -Parent (Split-Path -Parent $log) | Split-Path -Leaf
            [void]$found.Add([pscustomobject]@{
                Version      = ($version -replace '^Live\s+', '')
                IndexerLog   = $log
                LastIndexed  = $info.LastWriteTime
                UserLibrary  = ''
                HasDevicesDir = $false
            })
        }
    }
    return ,@($found | Sort-Object LastIndexed -Descending)
}

function Get-UserLibraryFromIndexer {
    <#
      The line we want looks like:
        ... Configure: UserLibrary: 'C:\Users\me\OneDrive\Documents\Ableton\User Library' [User Library]
      It appears once per index run, so take the LAST occurrence in the file.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $match = $null
    try {
        $hits = Select-String -LiteralPath $Path -Pattern "Configure:\s*UserLibrary:\s*'(.*)'\s*\[" -AllMatches -ErrorAction Stop
        if ($hits) { $match = $hits[-1].Matches[-1] }
    } catch { return '' }

    if (-not $match) { return '' }
    return $match.Groups[1].Value
}

# --------------------------------------------------------------------------- #

$candidates = Get-IndexerCandidates
foreach ($c in $candidates) {
    $c.UserLibrary = Get-UserLibraryFromIndexer -Path $c.IndexerLog
    if ($c.UserLibrary) {
        $c.HasDevicesDir = Test-Path -LiteralPath (Join-Path $c.UserLibrary 'Max for Live Devices')
    }
}

if ($List) {
    if (-not $candidates -or $candidates.Count -eq 0) {
        Write-Host 'No Ableton Live preference folders found, so there is no indexer log to read.'
        Write-Host 'Start Live once, then run this script again - or pass -UserLibrary <path> -Force.'
        exit 1
    }
    Write-Host ''
    Write-Host 'Live versions with an indexer log (newest activity first):'
    $candidates | ForEach-Object {
        Write-Host ('  Live {0,-10} last seen {1:yyyy-MM-dd HH:mm}  devices-dir={2,-5}  {3}' -f `
            $_.Version, $_.LastIndexed, $_.HasDevicesDir, $_.UserLibrary)
    }
    Write-Host ''
    exit 0
}

$chosen     = $null
$source     = ''

if ($UserLibrary) {
    $chosen = [pscustomobject]@{ Version = $LiveVersion; UserLibrary = (Expand-M4LPath $UserLibrary); IndexerLog = '' }
    $source = 'command line'
} else {
    $pool = $candidates
    if ($LiveVersion) {
        $pool = @($candidates | Where-Object { $_.Version -eq $LiveVersion -or $_.Version -like "$LiveVersion*" })
        if ($pool.Count -eq 0) { throw "No indexer log for Live $LiveVersion. Run with -List to see what is installed." }
    }
    # Prefer a log that actually named a User Library AND that path still exists.
    $usable = @($pool | Where-Object { $_.UserLibrary -and (Test-Path -LiteralPath $_.UserLibrary) })
    if ($usable.Count -gt 0) { $chosen = $usable[0]; $source = 'indexer log' }
    elseif ($pool.Count -gt 0) { $chosen = $pool[0]; $source = 'indexer log (path missing)' }
}

if (-not $chosen -or -not $chosen.UserLibrary) {
    # Last resort guesses, reported loudly rather than silently used.
    $guesses = @(
        (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Ableton\User Library'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Music\Ableton\User Library'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Music/Ableton/User Library')
    )
    $guesses = @($guesses | Where-Object { Test-Path -LiteralPath $_ })

    if ($guesses.Count -gt 0) {
        Write-Warning 'Could not read a User Library out of any indexer log.'
        Write-Warning 'Using a guess - confirm it before installing anything:'
        foreach ($g in $guesses) { Write-Warning "  $g" }
        $chosen = [pscustomobject]@{ Version = ''; UserLibrary = @($guesses)[0]; IndexerLog = '' }
        $source = 'fallback guess'
    } else {
        Write-Host ''
        Write-Host 'No Ableton Live User Library could be found.' -ForegroundColor Yellow
        Write-Host @'

  1. Start Ableton Live at least once (this creates the indexer log), then
     re-run:  scripts\detect-library.ps1 -List
  2. Or point at it directly:
     scripts\detect-library.ps1 -UserLibrary "<path to>\User Library" -Force

On Windows the log lives at %APPDATA%\Ableton\Live <VER>\Preferences\Indexer.txt
On macOS at ~/Library/Preferences/Ableton/Live <VER>/Indexer.txt
The line being read is:  Configure: UserLibrary: '<path>' [User Library]
'@
        exit 1
    }
}

$chosen.UserLibrary = $chosen.UserLibrary.TrimEnd('\', '/')

# --------------------------------------------------------------------------- #
# Sanity report
# --------------------------------------------------------------------------- #

Write-Host ''
Write-Host '========================================================='
Write-Host ' Max for Live harvester - library detection'
Write-Host '========================================================='
Write-Host (" Live version   : {0}" -f $(if ($chosen.Version) { $chosen.Version } else { 'unknown' }))
Write-Host (" Source         : {0}" -f $source)
if ($chosen.IndexerLog) { Write-Host (" Indexer log    : {0}" -f $chosen.IndexerLog) }
Write-Host (" User Library   : {0}" -f $chosen.UserLibrary)

$status = Get-UserLibraryStatus -UserLibrary $chosen.UserLibrary
Write-Host (" Max for Live   : {0}" -f $(if ($status.Ok) { 'Devices folder found' } else { $status.Reason }))

# The cloud-redirect trap: the folder Live uses is often NOT the one in Documents.
$docsLib = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Ableton\User Library'
if ($docsLib -and (Test-Path -LiteralPath $docsLib) -and ($docsLib.TrimEnd('\','/') -ne $chosen.UserLibrary)) {
    Write-Host ''
    Write-Warning "Documents contains a second User Library at:"
    Write-Warning "  $docsLib"
    Write-Warning "Live is indexing the one above instead. Devices copied into the Documents"
    Write-Warning "copy will not appear in Live's browser. This is exactly the OneDrive /"
    Write-Warning "cloud-redirect trap the detector exists to avoid."
}

if ($candidates.Count -gt 1) {
    Write-Host ''
    Write-Host ' Other Live versions found (install into a different one by re-running'
    Write-Host ' this script with -LiveVersion <ver> -Force):'
    foreach ($c in $candidates) {
        if ($c.Version -ne $chosen.Version) {
            Write-Host ('   Live {0,-10} -> {1}' -f $c.Version, $c.UserLibrary)
        }
    }
}

# --------------------------------------------------------------------------- #

$cfg = Get-M4LConfig -Config $Config -Quiet
if (-not $Force -and $cfg.userLibrary -and ($cfg.userLibrary -ne $chosen.UserLibrary)) {
    Write-Host ''
    Write-Warning "config.json already points at: $($cfg.userLibrary)"
    Write-Warning "Re-run with -Force to overwrite it with the detected path."
    exit 0
}

$cfg.userLibrary = $chosen.UserLibrary
if ($LiveVersion) { $cfg | Add-Member -NotePropertyName liveVersion -NotePropertyValue $LiveVersion -Force }
elseif ($chosen.Version) { $cfg | Add-Member -NotePropertyName liveVersion -NotePropertyValue $chosen.Version -Force }
if ($BuyerEmail)  { $cfg.buyerEmail  = $BuyerEmail }
if ($Collection)  { $cfg.collection  = $Collection }
if ($DownloadsDir) { $cfg.downloadsDir = (Expand-M4LPath $DownloadsDir) }

$target = Save-M4LConfig -Config $cfg -ConfigPath $Config

Write-Host ''
Write-Host (" Config written : {0}" -f $target)
Write-Host (" Collection     : {0}" -f (Join-Path $cfg.userLibrary ("Max for Live Devices\" + $cfg.collection)))
Write-Host (" Downloads      : {0}" -f $cfg.downloadsDir)
Write-Host (" Buyer email    : {0}" -f $(if ($cfg.buyerEmail) { $cfg.buyerEmail } else { '(not set - free Gumroad checkouts will need one)' }))
Write-Host ''
Write-Host ' Next: scripts\list-devices.ps1 -Pages 3'
Write-Host ''
