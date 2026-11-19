#requires -Version 5.1
<#
  build-queue.ps1 - turn the device inventory into a download queue.

  Reads devices.json (from list-devices.ps1) and writes queue.json plus a fresh
  state.json. Items already present in the User Library are marked 'have' so a
  re-run never re-downloads a device that is already installed.

  Queue item statuses:
      pending     waiting for run.ps1
      downloaded  a validated .amxd/.zip is sitting in the work downloads folder
      installed   copied into the User Library
      have        already present in the User Library before this run
      gated       the author removed the file, or it is behind a store front
      error       something unexpected; see Note
      manual      .alp pack - cannot be unpacked, must be dragged into Live

  Usage:
      scripts\build-queue.ps1
      scripts\build-queue.ps1 -Type instrument -Since 2024-01-01
      scripts\build-queue.ps1 -Take 50 -RebuildState
#>

[CmdletBinding()]
param(
    [string]$Config,
    [ValidateSet('any', 'instrument', 'midi', 'audio')][string]$Type = 'any',
    [string]$Since,                     # yyyy-MM-dd, filters on upload date
    [int]$Take = 0,                     # only the N newest, 0 = all
    [string[]]$Only,                    # explicit device ids
    [switch]$IncludeHave,
    [switch]$RebuildState
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg   = Get-M4LConfig -Config $Config
$paths = Get-M4LPaths -Config $cfg

if (-not (Test-Path -LiteralPath $paths.devicesFile)) {
    Write-Host "No device inventory yet at $($paths.devicesFile)"
    Write-Host 'Run scripts\list-devices.ps1 first.'
    exit 1
}

$devices = Read-JsonList -Path $paths.devicesFile
if ($devices.Count -eq 0) {
    Write-Host 'devices.json is empty. Run scripts\list-devices.ps1 first.'
    exit 1
}

# --------------------------------------------------------------------------- #
# What is already installed?
# --------------------------------------------------------------------------- #

$installedNames = @{}
$status = Get-UserLibraryStatus -UserLibrary $cfg.userLibrary
if ($status.Ok) {
    $existing = @(Get-ChildItem -LiteralPath $status.DevicesDir -Recurse -File -Filter '*.amxd' -ErrorAction SilentlyContinue)
    foreach ($f in $existing) { $installedNames[$f.BaseName.ToLower()] = $true }
    Write-Host "Found $($existing.Count) .amxd files already in the User Library."
} else {
    Write-Warning $status.Reason
    Write-Warning 'Every device will be queued as pending; installs will fail until config.json points at the real library.'
}

# --------------------------------------------------------------------------- #
# Filter + build
# --------------------------------------------------------------------------- #

$selected = New-Object System.Collections.ArrayList
foreach ($d in $devices) {
    if ($Only -and ($Only -notcontains [string]$d.Id)) { continue }
    if ($Type -ne 'any' -and (Get-Prop $d 'Type' 'any') -ne $Type) { continue }
    if ($Since) {
        $dateText = [string](Get-Prop $d 'Date' '')
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse($dateText, [ref]$parsed)) { continue }
        if ($parsed -lt ([datetime]$Since)) { continue }
    }
    [void]$selected.Add($d)
}

# newest first when a date is available, otherwise keep catalogue order
$ordered = @($selected | Sort-Object -Property @{ Expression = {
            $p = [datetime]::MinValue
            if ([datetime]::TryParse([string](Get-Prop $_ 'Date' ''), [ref]$p)) { $p } else { [datetime]'1900-01-01' }
        }; Descending = $true })

if ($Take -gt 0 -and $ordered.Count -gt $Take) { $ordered = $ordered[0..($Take - 1)] }

$queue = New-Object System.Collections.ArrayList
$seen  = @{}
foreach ($d in $ordered) {
    $id = [string]$d.Id
    if (-not $id -or $seen.ContainsKey($id)) { continue }
    $seen[$id] = $true

    $name = [string](Get-Prop $d 'Title' (Get-Prop $d 'Name' $id))

    $isInstalled = $false
    if ($installedNames.ContainsKey($name.ToLower())) { $isInstalled = $true }
    if ($installedNames.ContainsKey(([string]$id))) { $isInstalled = $true }

    if ($isInstalled -and -not $IncludeHave) { continue }

    [void]$queue.Add([pscustomobject]@{
        Id       = $id
        Name     = $name
        Author   = [string](Get-Prop $d 'Author' '')
        Type     = [string](Get-Prop $d 'Type' 'any')
        Date     = [string](Get-Prop $d 'Date' '')
        Slug     = [string](Get-Prop $d 'Slug' '')
        Status   = $(if ($isInstalled) { 'have' } else { 'pending' })
        Attempts = 0
        Kind     = ''
        File     = ''
        Note     = ''
    })
}

if ($queue.Count -eq 0) {
    Write-Host 'Nothing to queue: every matching device is already installed.'
    exit 0
}

$count = Write-JsonList -Path $paths.queueFile -Items @($queue)

if ($RebuildState -or -not (Test-Path -LiteralPath $paths.stateFile)) {
    $state = New-M4LState -Config $cfg
    Write-JsonObject -Path $paths.stateFile -Object $state
    Write-Host ("Pacing reset to {0:N1}s (min {1:N1}s / max {2:N1}s)." -f $state.delaySeconds, $state.minDelay, $state.maxDelay)
} else {
    Write-Host "Keeping learned pacing from $($paths.stateFile). Use -RebuildState to reset it."
}

$pending = @($queue | Where-Object { $_.Status -eq 'pending' }).Count
Write-Host ''
Write-Host ("Queue written : {0}" -f $paths.queueFile)
Write-Host ("Devices       : {0} ({1} pending, {2} already installed)" -f $count, $pending, ($count - $pending))
Write-Host ("ETA at start delay: ~{0} min" -f [math]::Round(($pending * [double]$cfg.pacing.startDelay) / 60, 1))
Write-Host ''
Write-Host ' Next: scripts\run.ps1 -MaxRuntimeMinutes 120'
