#requires -Version 5.1
<#
  gumroad-discover.ps1 - find the store front behind a gated device.

  A "gated" device is one whose maxforlive.com download answers "File not found".
  In most cases the author did not delete it: they moved distribution to
  Gumroad / Ko-fi / itch / Payhip / Lemon Squeezy and left the page up. This
  script reads the device page (not the download endpoint) and records any store
  front link it finds, so the next step can price-check it.

  Resumable: devices already recorded in gumroad-links.json are skipped, and the
  file is rewritten after every device.

  Note: this only reads a public page. It never touches a store front API and
  never authenticates anywhere.

  Usage:
      scripts\gumroad-discover.ps1
      scripts\gumroad-discover.ps1 -Refresh        # re-scan everything
      scripts\gumroad-discover.ps1 -MaxRuntimeMinutes 30
#>

[CmdletBinding()]
param(
    [string]$Config,
    [switch]$Refresh,
    [int]$MaxRuntimeMinutes = 120,
    [int]$Limit = 0
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg   = Get-M4LConfig -Config $Config
$paths = Get-M4LPaths -Config $cfg
$curl  = Get-CurlPath -Config $cfg
$ua    = $cfg.http.userAgent
$jar   = $paths.cookieJar
$tmp   = Join-Path $paths.workDir '_gumroad_page.html'

if (-not (Test-Path -LiteralPath $paths.queueFile)) {
    Write-Host "No queue at $($paths.queueFile). Run the harvest first."
    exit 1
}

$queue = Read-JsonList -Path $paths.queueFile
$gated = @($queue | Where-Object { $_.Status -eq 'gated' })
if ($gated.Count -eq 0) {
    Write-Host 'No gated devices in the queue - nothing to discover.'
    Write-Host '("gated" means maxforlive.com no longer serves the file.)'
    exit 0
}

$existing = @()
if (Test-Path -LiteralPath $paths.gumroadLinks) { $existing = Read-JsonList -Path $paths.gumroadLinks }
$known = @{}
foreach ($e in $existing) { $known[[string]$e.Id] = $e }

$todo = @($gated | Where-Object { $Refresh -or -not $known.ContainsKey([string]$_.Id) })
if ($Limit -gt 0 -and $todo.Count -gt $Limit) { $todo = $todo[0..($Limit - 1)] }

$state = Get-M4LState -Config $cfg -Path $paths.stateFile
$deadline = (Get-Date).AddMinutes($MaxRuntimeMinutes)

Write-M4LLog -Message "=== gumroad-discover start | gated=$($gated.Count) todo=$($todo.Count) ===" -LogFile $paths.runLog

$foundCount = 0
foreach ($g in $todo) {
    if ((Get-Date) -ge $deadline) { Write-Host 'runtime limit reached'; break }

    $pageUrl = "https://maxforlive.com/library/device/$($g.Id)/"
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    & $curl -sS -L -A $ua -c $jar -b $jar --max-time $cfg.http.requestTimeoutSeconds -o $tmp $pageUrl 2>$null | Out-Null

    $html = ''
    if (Test-Path -LiteralPath $tmp) {
        $html = [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    if ($html.Length -lt 500) {
        $kind = Test-M4LResponseBody -Text $html
        if ($kind -eq 'throttled') {
            $wait = Update-M4LPacing -State $state -Outcome 'throttled' -Config $cfg
            Write-JsonObject -Path $paths.stateFile -Object $state
            Write-Host ("  throttled - backing off {0:N1}s" -f $wait)
            Start-M4LWait -Seconds $wait
            continue        # retry the same device
        }
    }

    $link = ''
    $storeFront = ''
    foreach ($sf in $cfg.gumroad.storeFronts) {
        $m = [regex]::Match($html, 'https?://[^\s"''<>]*' + [regex]::Escape($sf) + '[^\s"''<>]*')
        if ($m.Success) { $link = $m.Value; $storeFront = $sf; break }
    }
    if ($link) {
        # strip tracking query strings, keep the path
        $link = ($link -split '\?')[0]
        # trailing punctuation from HTML attributes
        $link = $link.TrimEnd('.', ',', ')')
    }

    $record = [pscustomobject]@{
        Id         = [string]$g.Id
        Name       = [string]$g.Name
        Author     = [string]$g.Author
        Link       = $link
        StoreFront = $storeFront
        Status     = $(if ($link) { 'found' } else { 'no-link' })
        ScannedAt  = (Get-Date -Format 'o')
    }
    $known[[string]$g.Id] = $record

    if ($link) { $foundCount++; if ($record.StoreFront -eq 'gumroad.com') { Write-Host "  FOUND  $($g.Id) $($g.Name) -> $link" } }

    $wait = Update-M4LPacing -State $state -Outcome 'ok' -Config $cfg
    [void](Write-JsonList -Path $paths.gumroadLinks -Items @($known.Values))
    Write-JsonObject -Path $paths.stateFile -Object $state
    Start-M4LWait -Seconds $wait
}

$all = @($known.Values)
[void](Write-JsonList -Path $paths.gumroadLinks -Items $all)

Write-M4LLog -Message "=== gumroad-discover end | scanned=$($all.Count) with-link=$(@($all | Where-Object { $_.Link }).Count) ===" -LogFile $paths.runLog
Write-Host ''
Write-Host ("Scanned {0} gated devices, found {1} store front links this pass." -f $all.Count, $foundCount)
Write-Host ("Wrote {0}" -f $paths.gumroadLinks)
Write-Host ''
Write-Host ' Next: scripts\gumroad-price-probe.ps1'
