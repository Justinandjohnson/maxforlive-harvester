#requires -Version 5.1
<#
  inspect-amxd.ps1 - read the inside of a .amxd without opening Max.

  Container format:

      bytes  0.. 3   "ampf"                  magic
      bytes  4.. 7   int32 version           little endian
      bytes  8..11   "aaaa"                  marker
      bytes 12..     repeated chunks         4-char ASCII name, int32 size, data
                     e.g. "meta", "ptch", "mime", "more"

  CHUNKS START AT OFFSET 12. Every chunk is name(4) + size(4) + data(size), and
  the next chunk begins where the previous data ended.

  The "ptch" chunk holds the patch itself. It is either gzipped (starts 0x1f
  0x8b) or plain JSON starting at the first '{'. Some writers pad a header
  before the JSON, so always search for the first '{' rather than assuming
  offset 0 of the chunk.

  Why bother: the patch JSON lets you see which sidecar files a device needs
  (a .js engine, an .html UI, a sample), so you can tell whether an install
  dropped something, before Live shows an empty device.

  IMPORTANT - the "dependency_cache" trap:
  Max writes a dependency_cache array into saved patches. Those entries are the
  AUTHOR'S BUILD MANIFEST: absolute paths from their own machine
  ("C:/Users/someone/Documents/Max 8/Packages/..."). They are NOT runtime
  dependencies and their absence from your machine means nothing. Treating
  them as missing requirements is the single most common false alarm when
  auditing a downloaded device. Real runtime needs are the relative "file"
  references sitting next to the .amxd.

  Usage:
      scripts\inspect-amxd.ps1 -Path 'C:\...\Thing.amxd'
      scripts\inspect-amxd.ps1 -Path 'C:\...\Devices' -Recurse -Json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$Recurse,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'

function Get-AmxdInfo {
    param([Parameter(Mandatory = $true)][string]$File)

    $info = [ordered]@{
        Path           = $File
        SizeBytes      = 0
        Valid          = $false
        Version        = $null
        ChunkNames     = @()
        PatchFormat    = ''
        Deps           = @()          # relative / runtime-looking references
        DependencyCache= @()          # author's build manifest - ignore at runtime
        Errors         = @()
    }

    try { $bytes = [System.IO.File]::ReadAllBytes($File) } catch {
        $info.Errors += "cannot read: $($_.Exception.Message)"; return [pscustomobject]$info
    }
    $info.SizeBytes = $bytes.Length

    if ($bytes.Length -lt 16) { $info.Errors += 'file too short to be a device'; return [pscustomobject]$info }
    if (-not ($bytes[0] -eq 0x61 -and $bytes[1] -eq 0x6D -and $bytes[2] -eq 0x70 -and $bytes[3] -eq 0x66)) {
        $info.Errors += "bad magic: first 4 bytes are not 'ampf'"
        return [pscustomobject]$info
    }
    $info.Valid = $true
    $info.Version = [System.BitConverter]::ToInt32($bytes, 4)

    $marker = -join ($bytes[8..11] | ForEach-Object { [char]$_ })
    if ($marker -ne 'aaaa') { $info.Errors += "unexpected marker '$marker' (expected 'aaaa')" }

    # ---- chunks ----------------------------------------------------------- #
    $offset = 12
    $chunks = @{}
    $names  = New-Object System.Collections.ArrayList
    while ($offset + 8 -le $bytes.Length) {
        $name = -join ($bytes[$offset..($offset + 3)] | ForEach-Object { [char]$_ })
        if ($name -notmatch '^[ -~]{4}$') { $info.Errors += "non-ASCII chunk name at offset $offset"; break }

        $size = [System.BitConverter]::ToInt32($bytes, $offset + 4)
        if ($size -lt 0 -or ($offset + 8 + $size) -gt $bytes.Length) {
            $info.Errors += "chunk '$name' declares $size bytes but only $($bytes.Length - $offset - 8) remain"
            break
        }
        $dataStart = $offset + 8
        $chunks[$name] = @{ Offset = $dataStart; Size = $size }
        [void]$names.Add("$name($size)")
        $offset = $dataStart + $size
    }
    $info.ChunkNames = @($names)

    if (-not $chunks.ContainsKey('ptch')) { $info.Errors += "no 'ptch' chunk"; return [pscustomobject]$info }

    # ---- patch ------------------------------------------------------------ #
    $ptch = $chunks['ptch']
    $raw  = New-Object byte[] $ptch.Size
    [Array]::Copy($bytes, $ptch.Offset, $raw, 0, $ptch.Size)

    $text = ''
    if ($ptch.Size -gt 2 -and $raw[0] -eq 0x1F -and $raw[1] -eq 0x8B) {
        $info.PatchFormat = 'gzip'
        try {
            $in  = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, $raw)
            $gz  = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
            $out = New-Object System.IO.MemoryStream
            $gz.CopyTo($out)
            $gz.Dispose(); $in.Dispose()
            $text = [System.Text.Encoding]::UTF8.GetString($out.ToArray())
            $out.Dispose()
        } catch {
            $info.Errors += "ptch is gzip but would not decompress: $($_.Exception.Message)"
        }
    } else {
        $text = [System.Text.Encoding]::UTF8.GetString($raw)
        $info.PatchFormat = 'json'
    }

    $brace = $text.IndexOf('{')
    if ($brace -lt 0) {
        $info.Errors += 'no JSON found in the ptch chunk'
        return [pscustomobject]$info
    }
    $json = $text.Substring($brace)

    # ---- dependencies ----------------------------------------------------- #
    # Real runtime references live in the patch body: "file" attributes
    # (patcher includes, images, dialogs), "url" of a jweb box, and box text of
    # the form "js reader.js" / "mxj foo" / "node.script x.js".
    $set = @{}
    $patterns = @(
        '"file"\s*:\s*"([^"]+)"',
        '"url"\s*:\s*"([^"]+)"',
        '"text"\s*:\s*"(?:js|jsui|mxj|json|node\.script|n4m|vst~|pattrstorage|embedfile)\s+([^"\s]+)'
    )
    foreach ($pat in $patterns) {
        foreach ($m in [regex]::Matches($json, $pat)) {
            $v = $m.Groups[1].Value
            if (-not $v) { continue }
            if ($v -match '^(https?|file)://') { continue }   # external, not a sidecar
            if (-not $set.ContainsKey($v)) { $set[$v] = $true }
        }
    }
    $info.Deps = @($set.Keys | Sort-Object)

    $cache = @{}
    foreach ($m in [regex]::Matches($json, '(?s)"dependency_cache"\s*:\s*\[(.*?)\]\s*[,\}]')) {
        foreach ($n in [regex]::Matches($m.Groups[1].Value, '"name"\s*:\s*"([^"]+)"')) {
            $cache[$n.Groups[1].Value] = $true
        }
    }
    $info.DependencyCache = @($cache.Keys | Sort-Object)

    return [pscustomobject]$info
}

# --------------------------------------------------------------------------- #

$targets = @()
if (Test-Path -LiteralPath $Path -PathType Container) {
    $targets = @(Get-ChildItem -LiteralPath $Path -File -Filter '*.amxd' -Recurse:$Recurse -ErrorAction SilentlyContinue)
} else {
    $targets = @(Get-Item -LiteralPath $Path)
}

if ($targets.Count -eq 0) { Write-Host "No .amxd files at $Path"; exit 1 }

$all = @()
foreach ($t in $targets) { $all += Get-AmxdInfo -File $t.FullName }

if ($Json) {
    ConvertTo-Json -InputObject @($all) -Depth 6
    exit 0
}

foreach ($a in $all) {
    Write-Host ''
    Write-Host ('=== {0}' -f (Split-Path -Leaf $a.Path))
    Write-Host ('    size       : {0} KB' -f [math]::Round($a.SizeBytes / 1KB, 1))
    Write-Host ('    valid ampf : {0}' -f $a.Valid)
    if ($null -ne $a.Version) { Write-Host ('    version    : {0}' -f $a.Version) }
    if ($a.ChunkNames.Count -gt 0) { Write-Host ('    chunks     : {0}' -f ($a.ChunkNames -join ', ')) }
    if ($a.PatchFormat) { Write-Host ('    patch      : {0}' -f $a.PatchFormat) }

    if ($a.Deps.Count -gt 0) {
        Write-Host '    sidecar refs in the patch:'
        $dir = Split-Path -Parent $a.Path
        foreach ($d in $a.Deps) {
            $local = $null
            $rel = $d -replace '/', '\'
            if (-not [System.IO.Path]::IsPathRooted($rel)) { $local = Join-Path $dir $rel }
            $present = $local -and (Test-Path -LiteralPath $local)
            $flag = if ($present) { 'present' } else { '' }
            Write-Host ('      {0,-45} {1}' -f $d, $flag)
        }
    }

    if ($a.DependencyCache.Count -gt 0) {
        Write-Host ('    dependency_cache entries: {0}' -f $a.DependencyCache.Count)
        Write-Host '      (AUTHOR BUILD MANIFEST - absolute paths from their machine.'
        Write-Host '       NOT runtime requirements. Do not report these as missing.)'
        foreach ($c in ($a.DependencyCache | Select-Object -First 8)) { Write-Host "      $c" }
        if ($a.DependencyCache.Count -gt 8) { Write-Host '      ...' }
    }

    if ($a.Errors.Count -gt 0) {
        Write-Host '    warnings:'
        foreach ($e in $a.Errors) { Write-Host "      $e" }
    }
}
Write-Host ''
