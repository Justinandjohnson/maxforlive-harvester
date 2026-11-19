#requires -Version 5.1
<#
  list-devices.ps1 - inventory maxforlive.com's device library into devices.json.

  List pages look like:
      https://maxforlive.com/library/index.php?by=any&sortby=dev_date_added&pc=<N>
  with an optional &type=instrument | &type=midi | &type=audio filter.
  pc is 1-based. A page with no .device-item blocks means the end.

  Each <div class="device-item"> block contains:
      three <span class="day"> = month, day, year of the upload
      /library/device/<id>/<slug>            the device
      /profile/user/<author>                 the uploader
      <div class="library-device-description">  a truncated teaser

  Pacing matters here exactly as much as it does for downloads: this is the
  same host and the same HTTP 1015 rate limiter. Every page request goes
  through the shared state.json delay.

  Usage:
      scripts\list-devices.ps1 -Pages 3
      scripts\list-devices.ps1 -Pages 0 -Type instrument       # every page
      scripts\list-devices.ps1 -Pages 10 -Type midi -Fresh     # start over
#>

[CmdletBinding()]
param(
    [string]$Config,
    [int]$Pages = 5,
    [int]$StartPage = 1,
    [ValidateSet('any', 'instrument', 'midi', 'audio')][string]$Type = 'any',
    [string]$SortBy = 'dev_date_added',
    [int]$MaxRuntimeMinutes = 0,
    [switch]$Fresh,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg    = Get-M4LConfig -Config $Config
$paths  = Get-M4LPaths -Config $cfg
$state  = Get-M4LState -Config $cfg -Path $paths.stateFile
$curl   = Get-CurlPath -Config $cfg
$ua     = $cfg.http.userAgent
$jar    = $paths.cookieJar
$tmp    = Join-Path $paths.workDir '_page.html'

function Write-Log([string]$m) { Write-M4LLog -Message $m -LogFile $paths.runLog }

Write-Log "=== list-devices start | type=$Type pages=$Pages start=$StartPage sort=$SortBy ==="

# --------------------------------------------------------------------------- #
# Parsing
# --------------------------------------------------------------------------- #

function ConvertFrom-DeviceListPage {
    <#
      Splits the page on the literal 'device-item' marker and parses each
      fragment. Splitting on the marker is far more robust than trying to
      match nested <div>s: the markup around a device has changed before and
      will change again, but the marker itself is the anchor the site's own CSS
      depends on.
    #>
    param([Parameter(Mandatory = $true)][string]$Html, [string]$TypeHint = 'any')

    $items = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($Html)) { return ,$items.ToArray() }

    # String.Split(char[]) splits on EVERY CHARACTER of "device-item" - one
    # of the all-time great PowerShell traps. -split uses a regex.
    $fragments = $Html -split 'device-item'
    # fragment 0 is everything before the first device; skip it.
    for ($i = 1; $i -lt $fragments.Length; $i++) {
        $frag = $fragments[$i]
        # cut the fragment at the next device grid boundary noise (start of the
        # next block is already removed by the split, so this is bounded).

        $m = [regex]::Match($frag, '/library/device/(\d+)/([A-Za-z0-9_\-]+)')
        if (-not $m.Success) { continue }
        $id   = $m.Groups[1].Value
        $slug = $m.Groups[2].Value

        $author = ''
        $ma = [regex]::Match($frag, '/profile/user/([^"''\s<>/]+)')
        if ($ma.Success) { $author = [System.Net.WebUtility]::HtmlDecode($ma.Groups[1].Value) }

        $date = ''
        $days = [regex]::Matches($frag, '<span class="day">\s*([^<]*?)\s*</span>')
        if ($days.Count -ge 3) {
            $monthTxt = $days[0].Groups[1].Value
            $dayTxt   = $days[1].Groups[1].Value
            $yearTxt  = $days[2].Groups[1].Value
            $tryDate  = "$monthTxt $dayTxt $yearTxt"
            $parsed   = [datetime]::MinValue
            if ([datetime]::TryParse($tryDate, [ref]$parsed)) { $date = $parsed.ToString('yyyy-MM-dd') }
            else { $date = $tryDate }
        }

        # anchor text right before the author line is the display name
        $name = ''
        $mn = [regex]::Match($frag, '/library/device/\d+/[A-Za-z0-9_\-]+"\s*>([^<]*)</a>')
        if ($mn.Success) { $name = ([System.Net.WebUtility]::HtmlDecode($mn.Groups[1].Value)).Trim() }
        if (-not $name) { $name = $slug }

        $desc = ''
        $md = [regex]::Match($frag, '<div class="library-device-description">([\s\S]*?)</div>')
        if ($md.Success) {
            $desc = $md.Groups[1].Value
            $desc = $desc -replace '<br\s*/?>', ' '
            $desc = $desc -replace '<[^>]+>', ' '
            $desc = [System.Net.WebUtility]::HtmlDecode($desc)
            $desc = ($desc -replace '\s+', ' ').Trim()
        }

        $comments = ''
        $mc = [regex]::Match($frag, '([\d,]+)\s*<i class="fas fa-comments"')
        if ($mc.Success) { $comments = $mc.Groups[1].Value }

        # The anchor text usually carries the version glued to the name
        # ("CE1CE2Chorus1.0"); keep both so a readable title is available.
        $title = ($name -replace '\s*v?\d+(\.\d+)+$', '').Trim()
        if (-not $title) { $title = $name }

        [void]$items.Add([pscustomobject]@{
            Id         = $id
            Name       = $name
            Title      = $title
            Slug       = $slug
            Author     = $author
            Type       = $TypeHint
            Date       = $date
            Desc       = $desc
            Comments   = $comments
            Url        = "https://maxforlive.com/library/device/$id/$slug"
            DetectedAt = (Get-Date -Format 'o')
        })
    }
    return ,$items.ToArray()
}

# --------------------------------------------------------------------------- #
# Crawl
# --------------------------------------------------------------------------- #

if ($Fresh -and (Test-Path -LiteralPath $paths.devicesFile)) {
    Remove-Item -LiteralPath $paths.devicesFile -Force
}

$known = @{}
if (Test-Path -LiteralPath $paths.devicesFile) {
    $existing = Read-JsonList -Path $paths.devicesFile
    foreach ($d in $existing) { $known[[string]$d.Id] = $d }
    if (-not $Quiet) { Write-Host "Loaded $($known.Count) previously catalogued devices." }
}

$deadline = if ($MaxRuntimeMinutes -gt 0) { (Get-Date).AddMinutes($MaxRuntimeMinutes) } else { [datetime]::MaxValue }
$page = $StartPage
$pagesDone = 0
$newCount = 0
$lastPage = $false

while (-not $lastPage) {
    if ($Pages -gt 0 -and $pagesDone -ge $Pages) { break }
    if ((Get-Date) -ge $deadline) { Write-Log 'runtime limit reached'; break }

    $url = "https://maxforlive.com/library/index.php?by=any&sortby=$SortBy&pc=$page"
    if ($Type -ne 'any') { $url += "&type=$Type" }

    if (-not $Quiet) { Write-Host ("Fetching page {0} ... " -f $page) -NoNewline }
    & $curl -sS -L -A $ua -c $jar -b $jar --max-time $cfg.http.requestTimeoutSeconds `
        -o $tmp $url 2>$null | Out-Null

    $html = ''
    if (Test-Path -LiteralPath $tmp) {
        $html = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($html) -or $html.Length -lt 500) {
        $kind = Test-M4LResponseBody -Text $html
        if ($kind -eq 'throttled') {
            $wait = Update-M4LPacing -State $state -Outcome 'throttled' -Config $cfg
            Write-JsonObject -Path $paths.stateFile -Object $state
            Write-Log "THROTTLE on list page $page -> delay $([Math]::Round($state.delaySeconds,1))s, retry in $([Math]::Round($wait,1))s"
            Start-M4LWait -Seconds $wait -Reason 'throttled'
            continue     # same page, no increment: retry after backing off
        }
        Write-Log "empty response for page $page - stopping"
        break
    }

    $found = ConvertFrom-DeviceListPage -Html $html -TypeHint $Type
    $wait = Update-M4LPacing -State $state -Outcome 'ok' -Config $cfg
    Write-JsonObject -Path $paths.stateFile -Object $state

    if (-not $Quiet) { Write-Host ("{0} devices" -f $found.Count) }

    if ($found.Count -eq 0) { break }

    foreach ($d in $found) {
        if ($known.ContainsKey([string]$d.Id)) {
            # Keep our own bookkeeping but refresh the volatile fields.
            $prev = $known[[string]$d.Id]
            $prev.Name = $d.Name
            $prev.Title = $d.Title
            $prev.Author = $d.Author
            $prev.Date = $d.Date
            $prev.Desc = $d.Desc
            continue
        }
        $known[[string]$d.Id] = $d
        $newCount++
    }

    # A page that does not mention the next page number is the last page.
    if ($html -notmatch ("pc=" + ($page + 1) + '\b')) { $lastPage = $true }

    $pagesDone++
    $page++

    if ($pagesDone -eq 1 -or ($pagesDone % 10) -eq 0) {
        # persist every page: a crawl that dies at page 40 keeps pages 1-39
        $all = @($known.Values)
        [void](Write-JsonList -Path $paths.devicesFile -Items $all)
    }

    if (-not $lastPage) { Start-M4LWait -Seconds $wait }
}

$all = @($known.Values)
$count = Write-JsonList -Path $paths.devicesFile -Items $all

Write-Log "=== list-devices end | pages=$pagesDone new=$newCount total=$count delay=$([Math]::Round($state.delaySeconds,1))s ==="
if (-not $Quiet) {
    Write-Host ''
    Write-Host ("Catalogued {0} devices ({1} new) -> {2}" -f $count, $newCount, $paths.devicesFile)
    Write-Host ("Current pacing: {0:N1}s between requests" -f [double]$state.delaySeconds)
    Write-Host ''
    Write-Host ' Next: scripts\build-queue.ps1'
}
