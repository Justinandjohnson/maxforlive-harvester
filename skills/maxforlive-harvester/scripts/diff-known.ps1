#Requires -Version 5.1
<#
  diff-known.ps1 - compare the live maxforlive.com catalogue against seed/known-devices.json
                   and report ONLY what is new.

  Usage:
    .\diff-known.ps1                 # scan the newest ~10 pages, list anything not in the seed
    .\diff-known.ps1 -Pages 40       # go deeper back in time
    .\diff-known.ps1 -Json           # machine-readable output
    .\diff-known.ps1 -UpdateSeed     # also append the new finds to the seed

  Why: a full harvest is thousands of requests and hours of pacing. Most of that
  work has already been done once. This tells you what changed since, so a repeat
  run costs minutes instead of hours.
#>
param(
  [int]$Pages = 10,
  [switch]$Json,
  [switch]$UpdateSeed,
  [string]$SeedPath = (Join-Path $PSScriptRoot '..\seed\known-devices.json'),
  [string]$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
)

$ErrorActionPreference = 'Stop'
$curl = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } else { 'curl' }

function Read-JsonList([string]$path) {
  if (-not (Test-Path $path)) { return @() }
  $x = ConvertFrom-Json (Get-Content $path -Raw)
  # PowerShell 5.1 can nest arrays: @(ConvertFrom-Json ...) => one element containing the array
  if ($x -is [System.Array] -and $x.Count -eq 1 -and $x[0] -is [System.Array]) { return @($x[0]) }
  return @($x)
}

$seed = Read-JsonList $SeedPath
$known = @{}
foreach ($s in $seed) { if ($s.id) { $known[[string]$s.id] = $s } }

Write-Host "seed: $($known.Count) known devices"

$found = @()
$tmp = [System.IO.Path]::GetTempFileName()

for ($pc = 0; $pc -lt $Pages; $pc++) {
  $url = "https://maxforlive.com/library/index.php?by=any&tag=all&sortby=dev_date_added&pc=$pc"
  & $curl -sS -L -A $UserAgent --max-time 60 -o $tmp $url 2>$null | Out-Null
  if (-not (Test-Path $tmp)) { break }

  $html  = Get-Content $tmp -Raw
  $items = [regex]::Matches($html, '(?s)<div class="device-item">(.*?)<div class="library-device-bottom-area">')
  $count = 0
  foreach ($it in $items) {
    $b = $it.Groups[1].Value
    $lm = [regex]::Match($b, '/library/device/(\d+)/([^"]+)"')
    if (-not $lm.Success) { continue }
    $count++
    $id = $lm.Groups[1].Value
    if ($known.ContainsKey($id)) { continue }         # already seen - skip

    $dm = [regex]::Match($b, '(?s)<span class="day">([A-Za-z]{3})</span>\s*<span class="day">(\d+)</span>\s*<span class="day">(\d{4})</span>')
    $am = [regex]::Match($b, '/profile/user/([^"]+)"')
    $nm = [regex]::Match($b, '(?s)</div>\s*<a href="/library/device/\d+/[^"]+">([^<]+)</a>')
    $found += [pscustomobject]@{
      id      = $id
      name    = ($nm.Groups[1].Value -replace '&amp;','&').Trim()
      slug    = $lm.Groups[2].Value
      author  = $am.Groups[1].Value
      posted  = "$($dm.Groups[1].Value) $($dm.Groups[2].Value) $($dm.Groups[3].Value)".Trim()
      outcome = 'untried'
    }
  }
  Write-Host "page $pc -> $count listed, $($found.Count) new so far"
  if ($count -eq 0) { break }
  Start-Sleep -Milliseconds 2500                      # stay well inside the rate limit
}

Remove-Item $tmp -Force -ErrorAction SilentlyContinue

if ($Json) {
  ConvertTo-Json -InputObject @($found) -Depth 4
} else {
  if ($found.Count -eq 0) {
    Write-Host "`nNothing new since the seed. Nothing to do."
  } else {
    Write-Host "`n=== $($found.Count) NEW devices not in the seed ==="
    $found | Sort-Object posted | Format-Table id, posted, name, author -AutoSize
  }
}

if ($UpdateSeed -and $found.Count -gt 0) {
  $merged = @($seed) + @($found)
  ConvertTo-Json -InputObject @($merged) -Depth 4 | Set-Content $SeedPath -Encoding UTF8
  Write-Host "`nseed updated: $($merged.Count) devices"
}
