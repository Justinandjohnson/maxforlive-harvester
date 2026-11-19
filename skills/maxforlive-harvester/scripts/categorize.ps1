#requires -Version 5.1
<#
  categorize.ps1 - group installed devices and emit CATALOG.md.

  Input (whatever exists):
      <work>\devices.json           from list-devices.ps1  (Id, Title, Desc, Author, Type)
      <UserLibrary>\Max for Live Devices\**\*.amxd
      <work>\downloads\*.amxd

  Devices are de-duplicated by name, preferring an installed copy. Metadata is
  matched by the "[<id>]" suffix the harvester puts on files, then by name.

  Output:
      <work>\CATALOG.md      "Start here" + one table per category
      <work>\catalog-data.json   the raw rows, for your own tooling

  Honesty rule: if the site had no usable description, the row SAYS SO and the
  text is inferred from the device name. Never present a guess as a fact - the
  whole point of the catalogue is to know which rows you can trust.

  Usage:
      scripts\categorize.ps1
      scripts\categorize.ps1 -CopyTo "$($env:USERPROFILE)\Desktop"
#>

[CmdletBinding()]
param(
    [string]$Config,
    [string]$OutFile,
    [string]$CopyTo,
    [int]$StartHereCount = 8
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg   = Get-M4LConfig -Config $Config
$paths = Get-M4LPaths -Config $cfg

# --------------------------------------------------------------------------- #
# Metadata
# --------------------------------------------------------------------------- #

$meta = @{}          # id -> device record
$byName = @{}        # lowercase title -> device record
if (Test-Path -LiteralPath $paths.devicesFile) {
    foreach ($d in (Read-JsonList -Path $paths.devicesFile)) {
        $id = [string]$d.Id
        if ($id) { $meta[$id] = $d }
        $title = [string](Get-Prop $d 'Title' (Get-Prop $d 'Name' ''))
        if ($title) { $byName[$title.ToLower()] = $d }
    }
}

# --------------------------------------------------------------------------- #
# Collect files
# --------------------------------------------------------------------------- #

$files = New-Object System.Collections.ArrayList

$status = Get-UserLibraryStatus -UserLibrary $cfg.userLibrary
if ($status.Ok) {
    foreach ($f in @(Get-ChildItem -LiteralPath $status.DevicesDir -Recurse -File -Filter '*.amxd' -ErrorAction SilentlyContinue)) {
        [void]$files.Add([pscustomobject]@{ Path = $f.FullName; Name = $f.BaseName; Where = 'installed' })
    }
}
foreach ($f in @(Get-ChildItem -LiteralPath $paths.downloads -File -Filter '*.amxd' -ErrorAction SilentlyContinue)) {
    [void]$files.Add([pscustomobject]@{ Path = $f.FullName; Name = $f.BaseName; Where = 'downloaded' })
}

if ($files.Count -eq 0) {
    Write-Host 'No .amxd files found in the User Library or the download cache.'
    Write-Host 'Run scripts\list-devices.ps1 + run.ps1 -Install first.'
    exit 1
}

# --------------------------------------------------------------------------- #
# Classification
# --------------------------------------------------------------------------- #

$rules = [ordered]@{
    'Push & Session Control'        = @('push', 'push2', 'push3', 'scene', 'session', 'red box', 'usermode', 'user mode', 'clip launch', 'takeover', 'illumination', 'rgb', 'launch')
    'Chords & Harmony'              = @('chord', 'harmony', 'harmonic', 'voicing', 'inversion', 'roman', 'cadence', 'progression', 'scale', 'key', 'interval', 'strummer', 'strum')
    'Drums & Percussion'            = @('drum', 'kick', 'snare', 'hat', 'percussion', 'clap', 'rim', 'tom', '909', '808', '606', 'breakbeat', 'groove', 'beat')
    'Samplers & Granular'           = @('sampler', 'sample', 'granular', 'grain', 'slice', 'slicer', 'chop', 'buffer', 'wavetable', 'corpus', 'cloud', 'stretch', 'loop')
    'Sequencers & Pattern Generators' = @('sequencer', 'seq', 'step', 'arp', 'arpegg', 'euclid', 'pattern', 'generator', 'shift register', 'clock', 'trigger', 'divider', 'probability', 'quantize', 'tempo')
    'Modulation'                    = @('lfo', 'modulat', 'envelope', 'follower', 'chaos', 'attractor', 'drift', 'automation', 'morph', 'macro')
    'Audio Effects'                 = @('reverb', 'verb', 'delay', 'echo', 'filter', 'compress', 'distort', 'drive', 'saturat', 'width', 'shimmer', 'chorus', 'flanger', 'phaser', 'eq', 'glitch', 'tape', 'gate', 'ducker', 'meter', 'loudness', 'limiter', 'crusher', 'shaper')
    'Synths'                        = @('synth', 'osc', 'oscillator', 'fm', 'additive', 'subtractive', 'analog', 'mono', 'poly', 'voice', 'waveguide', 'physical model', 'resonator', 'vco', 'vcf', 'pulse', 'pad')
    'Utilities'                     = @('export', 'latency', 'monitor', 'editor', 'wrapper', 'bridge', 'converter', 'mapping', 'utility', 'manager', 'explorer', 'info', 'reset', 'rename', 'color', 'colour', 'csv', 'midi', 'sysex', 'osc', 'meter', 'note', 'clip', 'warp', 'tempo map')
}
$categoryOrder = @(
    'Synths',
    'Drums & Percussion',
    'Samplers & Granular',
    'Sequencers & Pattern Generators',
    'Chords & Harmony',
    'Modulation',
    'Audio Effects',
    'Push & Session Control',
    'Utilities',
    'Experimental'
)

function Get-Category {
    param([string]$Name, [string]$Desc)

    $nameL = $Name.ToLower()
    $descL = $Desc.ToLower()
    $best = 'Experimental'
    $bestScore = 0

    foreach ($cat in $rules.Keys) {
        $score = 0
        foreach ($w in $rules[$cat]) {
            if ($nameL.Contains($w)) { $score += 3 }
            if ($descL.Contains($w)) { $score += 1 }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $cat }
    }
    return $best
}

$reach = @{
    'Synths'                         = 'you need a sound source - a lead, a bass, a pad - without loading an instrument.'
    'Drums & Percussion'             = 'you want synthetic hits instead of samples: tuneable kicks, snapping hats.'
    'Samplers & Granular'            = 'a sample needs to become something else: stretched, chopped, scattered into grains.'
    'Sequencers & Pattern Generators' = 'you want the notes written for you so you can shape tone and groove instead of clicking.'
    'Chords & Harmony'               = 'you are stuck on what chord comes next, or you want to see what you are playing.'
    'Modulation'                     = 'a parameter never moves on its own and the sound feels static.'
    'Audio Effects'                  = 'the material exists but sounds flat, thin, or stuck in one place.'
    'Push & Session Control'         = 'you are playing Live on Push and want the hardware to do more than the defaults.'
    'Utilities'                      = 'you need a job done around the music: mapping, exporting, metering, translating.'
    'Experimental'                   = 'you want to be surprised rather than solve a specific problem.'
}

function Get-TrimmedDescription {
    param([string]$Text, [int]$Max = 210)

    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -le $Max) { return $t }
    $cut = $t.Substring(0, $Max)
    $stop = [Math]::Max($cut.LastIndexOf('. '), $cut.LastIndexOf('; '))
    if ($stop -gt 80) { return $cut.Substring(0, $stop + 1).Trim() }
    return ($cut.TrimEnd(',', ' ') + '...')
}

# --------------------------------------------------------------------------- #
# Build rows
# --------------------------------------------------------------------------- #

$rows = New-Object System.Collections.ArrayList
$seen = @{}

foreach ($f in $files) {
    $id = ''
    $m = [regex]::Match($f.Name, '\[(\d+)\]$')
    if ($m.Success) { $id = $m.Groups[1].Value }

    $rec = $null
    if ($id -and $meta.ContainsKey($id)) { $rec = $meta[$id] }

    $display = if ($rec) { [string](Get-Prop $rec 'Title' (Get-Prop $rec 'Name' $f.Name)) } else { ($f.Name -replace '\s*\[\d+\]$', '') }
    if (-not $display) { $display = $f.Name }
    if ($display -notmatch '\[\d+\]$' -and -not $id) { $display = $f.Name }

    if (-not $rec) {
        $hit = $byName[$display.ToLower()]
        if ($hit) { $rec = $hit }
    }

    $key = $display.ToLower()
    if ($seen.ContainsKey($key)) {
        if ($f.Where -eq 'installed' -and $seen[$key].Where -ne 'installed') { $seen[$key].Where = 'installed' }
        continue
    }

    $desc = ''
    if ($rec) { $desc = ([string](Get-Prop $rec 'Desc' '')).Trim() }
    # A "description" that is just marketing boilerplate or a link is not usable.
    $usable = ($desc.Length -ge 40) -and ($desc -notmatch '^\s*(https?://|www\.)') -and ($desc -notmatch '^\s*(check out|support me|follow me)')

    $cat = Get-Category -Name $display -Desc $desc

    $what = if ($usable) {
        Get-TrimmedDescription -Text $desc
    } else {
        "No usable description on the site; name suggests: $display."
    }

    $row = [pscustomobject]@{
        Category = $cat
        Device   = $display
        Id       = $id
        Author   = if ($rec) { [string](Get-Prop $rec 'Author' '') } else { '' }
        Where    = $f.Where
        Path     = $f.Path
        Desc     = $desc
        Inferred = (-not $usable)
        What     = $what
        ReachFor = $reach[$cat]
    }
    $seen[$key] = $row
    [void]$rows.Add($row)
}

# --------------------------------------------------------------------------- #
# Start here shortlist
# --------------------------------------------------------------------------- #

$priority = @('Chords & Harmony', 'Audio Effects', 'Synths', 'Sequencers & Pattern Generators', 'Drums & Percussion', 'Samplers & Granular', 'Modulation', 'Push & Session Control')
$shortlist = New-Object System.Collections.ArrayList
foreach ($cat in $priority) {
    if ($shortlist.Count -ge $StartHereCount) { break }
    $cand = @($rows | Where-Object { $_.Category -eq $cat -and -not $_.Inferred } |
              Sort-Object { $_.Device.Length } | Select-Object -First 1)
    if ($cand.Count -eq 0) {
        # fall back to a documented-by-name device in that category
        $cand = @($rows | Where-Object { $_.Category -eq $cat } | Sort-Object { $_.Device.Length } | Select-Object -First 1)
    }
    if ($cand.Count -gt 0) { [void]$shortlist.Add($cand[0]) }
}

# --------------------------------------------------------------------------- #
# Write CATALOG.md
# --------------------------------------------------------------------------- #

$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$s) { [void]$sb.AppendLine($s) }

$inferredCount = @($rows | Where-Object { $_.Inferred }).Count
$installedCount = @($rows | Where-Object { $_.Where -eq 'installed' }).Count

Add-Line '# Max for Live Catalog'
Add-Line ''
Add-Line ("{0} devices ({1} installed, {2} still only in the download cache)." -f $rows.Count, $installedCount, ($rows.Count - $installedCount))
Add-Line ''
if ($inferredCount -gt 0) {
    Add-Line ("> {0} of {1} rows had no usable description on the site. Those rows say so, and their" -f $inferredCount, $rows.Count)
    Add-Line '> "what it does" is inferred from the device name alone. Treat them as guesses.'
    Add-Line ''
}

Add-Line '## Start here'
Add-Line ''
Add-Line 'One device per category that is documented well enough to trust.'
Add-Line ''
foreach ($s in $shortlist) {
    $why = if ($s.Inferred) { '(name only - unverified)' } else { (Get-TrimmedDescription -Text $s.Desc -Max 130) }
    Add-Line ("- **{0}** - {1}" -f $s.Device, $why)
}
Add-Line ''

foreach ($cat in $categoryOrder) {
    $group = @($rows | Where-Object { $_.Category -eq $cat } | Sort-Object Device)
    if ($group.Count -eq 0) { continue }

    Add-Line ("## {0}  ({1})" -f $cat, $group.Count)
    Add-Line ''
    Add-Line '| Device | What it does | Reach for it when |'
    Add-Line '| --- | --- | --- |'
    foreach ($r in $group) {
        $what = $r.What -replace '\|', '/'
        $when = $r.ReachFor -replace '\|', '/'
        Add-Line ("| {0} | {1} | {2} |" -f ($r.Device -replace '\|', '/'), $what, $when)
    }
    Add-Line ''
}

Add-Line '---'
Add-Line ''
Add-Line 'Generated by scripts\categorize.ps1. Categories are keyword-scored on device name + description,'
Add-Line 'so a mis-filed device means the keywords need a tweak, not that the device is broken.'

$md = $sb.ToString()
$target = if ($OutFile) { $OutFile } else { $paths.catalogMd }
[System.IO.File]::WriteAllText($target, $md, (New-Object System.Text.UTF8Encoding($false)))

$dataFile = $paths.catalogFile
[void](Write-JsonList -Path $dataFile -Items @($rows))

if ($CopyTo) {
    $dest = Join-Path $CopyTo 'CATALOG.md'
    Copy-Item -LiteralPath $target -Destination $dest -Force
    Write-Host "Copied to $dest"
}

Write-Host ''
Write-Host ("Catalogued {0} devices ({1} installed, {2} with inferred descriptions)." -f $rows.Count, $installedCount, $inferredCount)
Write-Host ''
foreach ($cat in $categoryOrder) {
    $n = @($rows | Where-Object { $_.Category -eq $cat }).Count
    if ($n -gt 0) { Write-Host ("  {0,-34} {1,4}" -f $cat, $n) }
}
Write-Host ''
Write-Host ("Wrote {0}" -f $target)
Write-Host ("Wrote {0}" -f $dataFile)
