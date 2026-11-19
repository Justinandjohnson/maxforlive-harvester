#requires -Version 5.1
<#
  install-m4l.ps1 - validate and place a downloaded M4L payload into the User Library.

  Placement rules (they are not arbitrary - they are what Live expects):

    single .amxd, no sidecar files
        <UserLibrary>/Max for Live Devices/<Collection>/<Name>.amxd

    .amxd plus sibling .js / .html / .json / .png / .maxpat
        <UserLibrary>/Presets/Max MIDI Effect/<Name>/<everything>
      A device whose patch reads a sidecar (a JS engine, an html UI, a JSON
      preset table) only works when the sidecar resolves relative to it. Live's
      Presets tree keeps the folder together; dropping the loose .amxd into
      Max for Live Devices breaks the device.

    .alp pack
        NOT installable by script. An .alp is Ableton's proprietary "pl-a"
        container. It must be dragged onto Live (or double-clicked) once. This
        script reports it and exits 4.

  Zip handling: Expand-Archive fails on a lot of M4L zips (bit-7 filenames,
  entries with backslashes, absolute paths, no explicit directory entries).
  OpenRead + ExtractToFile per entry handles all of those, and .NET Framework
  has no ExtractToDirectory overload that overwrites, so the per-entry loop is
  the only option that is safe to re-run.

  Usage:
      scripts\install-m4l.ps1 -Path '<work>\downloads\Thing [123].amxd'
      scripts\install-m4l.ps1 -Path '<work>\downloads\Pack [456].zip' -Name 'Pack'
      scripts\install-m4l.ps1 -Path ... -WhatIfOnly
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [string]$Config,
    [string]$Name,                  # folder / file leaf name, defaults to the file name
    [string]$Collection,            # defaults to config.collection
    [switch]$KeepSourceTrees,       # do not quarantine C++/IDE source folders
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
. (Join-Path $PSScriptRoot '_common.ps1')

# Exit codes
#   0 ok   1 missing input   2 not a valid .amxd   3 unsupported type
#   4 .alp (manual)          5 unsafe zip entry
$EXIT_OK       = 0
$EXIT_MISSING  = 1
$EXIT_BADAMXD  = 2
$EXIT_UNSUP    = 3
$EXIT_MANUAL   = 4
$EXIT_ZIPSLIP  = 5

$cfg = Get-M4LConfig -Config $Config
if (-not $Collection) { $Collection = $cfg.collection }

$status = Get-UserLibraryStatus -UserLibrary $cfg.userLibrary
if (-not $status.Ok) {
    Write-Output "LIBRARY-NOT-READY: $($status.Reason)"
    exit $EXIT_UNSUP
}

$lib = $cfg.userLibrary
if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output "MISSING: $Path"
    exit $EXIT_MISSING
}

$file = Get-Item -LiteralPath $Path
$ext  = $file.Extension.ToLower()
if (-not $Name) { $Name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
$leaf = ConvertTo-SafeName $Name

$devicesRoot = Join-Path $lib 'Max for Live Devices'
$presetsRoot = Join-Path $lib 'Presets\Max MIDI Effect'
$quarantine  = Join-Path $cfg.workDir 'quarantine'

function New-Directory([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# --------------------------------------------------------------------------- #
# .alp : explain, never fake an install
# --------------------------------------------------------------------------- #

if ($ext -eq '.alp') {
    $sig = Get-FileSignature -Path $Path
    Write-Output "ALP-PACK: $($file.FullName)"
    Write-Output "ALP-HEADER: $($sig.Header)"
    Write-Output 'ALP-NOTE: .alp is a proprietary "pl-a" container (Ableton pack). It cannot be unpacked'
    Write-Output 'ALP-NOTE: by any public tool. Drag the file onto Live, or double-click it, then follow'
    Write-Output 'ALP-NOTE: Live''s own install prompt. Nothing was written to the User Library.'
    exit $EXIT_MANUAL
}

# --------------------------------------------------------------------------- #
# plain .amxd
# --------------------------------------------------------------------------- #

if ($ext -eq '.amxd') {
    if (-not (Test-AmpfFile $Path)) {
        Write-Output "BAD-AMXD: $($file.FullName) (first 4 bytes are not 'ampf')"
        exit $EXIT_BADAMXD
    }
    $dest = Join-Path $devicesRoot $Collection
    $target = Join-Path $dest ("$leaf.amxd")
    if ($WhatIfOnly) { Write-Output "WOULD-COPY: $target"; exit $EXIT_OK }
    New-Directory $dest
    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    Write-Output "INSTALLED-AMXD: $target"
    exit $EXIT_OK
}

# --------------------------------------------------------------------------- #
# zip
# --------------------------------------------------------------------------- #

if ($ext -ne '.zip') {
    Write-Output "UNSUPPORTED: $ext ($($file.FullName))"
    Write-Output 'UNSUPPORTED-NOTE: expected .amxd, .zip or .alp'
    exit $EXIT_UNSUP
}

$sig = Get-FileSignature -Path $Path
if ($sig.Kind -ne 'zip') {
    Write-Output "BAD-ZIP: $($file.FullName) (no PK header, size $($sig.Size) bytes)"
    exit $EXIT_UNSUP
}

$staging = Join-Path $cfg.workDir ('_stage\' + $leaf)
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Directory $staging

$zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
$count = 0
$bad = New-Object System.Collections.ArrayList
$slip = $null
try {
    foreach ($entry in $zip.Entries) {
        $full = $entry.FullName
        if (-not $full) { continue }
        if ($full -match '(^|/)__MACOSX(/|$)') { continue }             # macOS resource forks
        if ($full -match '(^|/)\.DS_Store$') { continue }
        if ($full.EndsWith('/') -or $full.EndsWith('\')) { continue }    # directory entry

        $rel = $full -replace '\\', '/'
        # Zip-slip guard: refuse absolute paths and any ../ traversal.
        if ($rel.StartsWith('/') -or $rel -match '^[A-Za-z]:' -or $rel -match '(^|/)\.\.(/|$)') {
            $slip = $full
            break
        }

        $outPath = Join-Path $staging ($rel -replace '/', '\')
        $outDir  = [System.IO.Path]::GetDirectoryName($outPath)
        if ($outDir) { New-Directory $outDir }

        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $outPath, $true)
        $count++
        if ($outPath.ToLower().EndsWith('.amxd') -and -not (Test-AmpfFile $outPath)) { [void]$bad.Add($outPath) }
    }
} finally {
    $zip.Dispose()
}

if ($slip) {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output "UNSAFE-ZIP: entry '$slip' would escape the destination. Nothing installed."
    exit $EXIT_ZIPSLIP
}

if ($WhatIfOnly) {
    Write-Output "WOULD-EXTRACT: $count files to $staging"
    exit $EXIT_OK
}

if ($bad.Count -gt 0) {
    Write-Output ('BAD-AMXD: ' + ($bad -join '; '))
    Write-Output 'BAD-AMXD-NOTE: those entries are not Max device binaries. Nothing was installed.'
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    exit $EXIT_BADAMXD
}

Write-Output "EXTRACTED: $count files"

# --------------------------------------------------------------------------- #
# Pack hygiene: get build trees out of the User Library before Live indexes them
# --------------------------------------------------------------------------- #

if (-not $KeepSourceTrees) {
    $junkFileGlobs = @('*.sln', '*.vcxproj', '*.vcproj', '*.suo', '*.ncb', 'Makefile', 'CMakeLists.txt')
    $junkDirs      = @('Source', 'Sources', 'src', 'VS2012', 'VS2013', 'VS2015', 'VS2017', 'VS2019', 'VS2022',
                       'x64', 'Win32', 'Debug', 'Release', 'xcode', 'build', 'buildsrc', '.git', '.vs')

    $moved = New-Object System.Collections.ArrayList
    $movedPrefixes = New-Object System.Collections.ArrayList
    $quarantineTarget = Join-Path $quarantine $leaf
    New-Directory $quarantineTarget

    # Directories first, shallowest first, so a whole build tree disappears in
    # one move instead of failing on children that no longer exist.
    $dirs = @(Get-ChildItem -LiteralPath $staging -Directory -Recurse -ErrorAction SilentlyContinue |
              Sort-Object { $_.FullName.Length })
    foreach ($d in $dirs) {
        if ($junkDirs -notcontains $d.Name) { continue }
        $already = $false
        foreach ($pre in $movedPrefixes) { if ($d.FullName.StartsWith($pre)) { $already = $true; break } }
        if ($already) { continue }

        $rel = $d.FullName.Substring($staging.Length).TrimStart('\')
        $destPath = Join-Path $quarantineTarget $rel
        $destParent = Split-Path -Parent $destPath
        New-Directory $destParent
        if (Test-Path -LiteralPath $destPath) { Remove-Item -LiteralPath $destPath -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $d.FullName -Destination $destPath -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $d.FullName)) {
            [void]$movedPrefixes.Add($d.FullName)
            [void]$moved.Add($rel + '\')
        }
    }

    foreach ($g in $junkFileGlobs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $staging -File -Recurse -Filter $g -ErrorAction SilentlyContinue)) {
            $rel = $f.FullName.Substring($staging.Length).TrimStart('\')
            $destDir = Join-Path $quarantineTarget ([System.IO.Path]::GetDirectoryName($rel))
            New-Directory $destDir
            Move-Item -LiteralPath $f.FullName -Destination (Join-Path $destDir $f.Name) -Force -ErrorAction SilentlyContinue
            [void]$moved.Add($rel)
        }
    }
    if ($moved.Count -gt 0) {
        Write-Output ("QUARANTINED: {0} build artefacts moved to {1}" -f $moved.Count, $quarantineTarget)
        Write-Output 'QUARANTINED-NOTE: Live''s indexer chokes on C++/IDE project trees inside the User Library.'
        Write-Output 'QUARANTINED-NOTE: The device itself does not need them at runtime.'
    }
}

# --------------------------------------------------------------------------- #
# Decide the final home
# --------------------------------------------------------------------------- #

$all = @(Get-ChildItem -LiteralPath $staging -Recurse -File -ErrorAction SilentlyContinue)
$amxd = @($all | Where-Object { $_.Extension -eq '.amxd' })
$sidecarExts = @('.js', '.html', '.htm', '.json', '.png', '.jpg', '.svg', '.maxpat', '.maxhelp', '.txt', '.wav', '.aiff', '.amxd')
$sidecar = @($all | Where-Object { $sidecarExts -contains $_.Extension.ToLower() -and $_.Extension -ne '.amxd' })

if ($amxd.Count -eq 0) {
    Write-Output "NO-AMXD: the zip contained $($all.Count) files but no .amxd"
    Write-Output ('NO-AMXD-CONTENTS: ' + (($all | Select-Object -First 12 | ForEach-Object { $_.Name }) -join ', '))
    Write-Output "NO-AMXD-STAGING: left at $staging"
    exit $EXIT_UNSUP
}

# Collapse a single wrapping directory ("Thing/Thing.amxd" -> "Thing")
$top = @(Get-ChildItem -LiteralPath $staging -Force)
if ($top.Count -eq 1 -and $top[0].PSIsContainer) {
    $staging = $top[0].FullName
    $all = @(Get-ChildItem -LiteralPath $staging -Recurse -File -ErrorAction SilentlyContinue)
    $amxd = @($all | Where-Object { $_.Extension -eq '.amxd' })
    $sidecar = @($all | Where-Object { $sidecarExts -contains $_.Extension.ToLower() -and $_.Extension -ne '.amxd' })
}

$needsPresets = ($amxd.Count -eq 1) -and ($sidecar.Count -gt 0)

if ($needsPresets) {
    $target = Join-Path $presetsRoot $leaf
    New-Directory (Split-Path -Parent $target)
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    Move-Item -LiteralPath $staging -Destination $target -Force
    Write-Output "INSTALLED-PRESET-FOLDER: $target"
    Write-Output ("INSTALLED-NOTE: device has {0} sidecar file(s), so it lives in Presets\Max MIDI Effect and keeps them together." -f $sidecar.Count)
    exit $EXIT_OK
}

# No sidecars (or several devices): one folder per collective name under the
# collection folder so a multi-device zip stays together and is easy to delete.
$target = Join-Path (Join-Path $devicesRoot $Collection) $leaf
New-Directory (Split-Path -Parent $target)
if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
Move-Item -LiteralPath $staging -Destination $target -Force
Write-Output "INSTALLED-FOLDER: $target"
foreach ($a in $amxd) {
    Write-Output ("AMXD: " + $a.FullName.Substring($target.Length + 1) + " (" + [math]::Round($a.Length / 1KB) + " KB)")
}
exit $EXIT_OK
