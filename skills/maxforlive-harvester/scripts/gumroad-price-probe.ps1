#requires -Version 5.1
<#
  gumroad-price-probe.ps1 - read the real asking price for each discovered link.

  Reads the product page's own metadata:

      <meta property="product:price:amount" content="0">
      <meta property="product:price:currency" content="USD">
      "permalink":"abcdef"

  and builds the canonical checkout URL:

      https://gumroad.com/checkout?product=<permalink>

  Naive "click I want this" on a Gumroad product page does nothing: the modern
  product page is an Inertia SPA and the button is wired to client-side state,
  so a scripted click silently no-ops. Navigating to /checkout?product=<permalink>
  is the reliable route, and it shows the real cart.

  IMPORTANT: the listing price and the cart total are not the same thing. A
  product that advertises "$0+" (pay what you want) can still put a non-zero
  total in the cart, and a "$0" listing can carry a minimum. The probe records
  what the page says; the operator must still confirm the cart total is 0.00
  before submitting. See SKILL.md for the checkout rules.

  Output: gumroad-prices.json
      Id, Name, Link, Permalink, Amount, Currency, Verdict, CheckoutUrl, Note
      Verdict: free | paid | unknown

  Usage:
      scripts\gumroad-price-probe.ps1
      scripts\gumroad-price-probe.ps1 -Rerun   # re-probe everything
#>

[CmdletBinding()]
param(
    [string]$Config,
    [switch]$Rerun,
    [int]$DelayMilliseconds = 800,
    [int]$Retries = 2
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg   = Get-M4LConfig -Config $Config
$paths = Get-M4LPaths -Config $cfg

if (-not (Test-Path -LiteralPath $paths.gumroadLinks)) {
    Write-Host "No gumroad-links.json yet. Run scripts\gumroad-discover.ps1 first."
    exit 1
}

$links = Read-JsonList -Path $paths.gumroadLinks
$rows  = @($links | Where-Object { $_.Link })
if ($rows.Count -eq 0) { Write-Host 'No store front links recorded.'; exit 0 }

$done = @{}
if (-not $Rerun -and (Test-Path -LiteralPath $paths.gumroadPrices)) {
    foreach ($p in (Read-JsonList -Path $paths.gumroadPrices)) { $done[[string]$p.Id] = $p }
}

$out = New-Object System.Collections.ArrayList
foreach ($r in $rows) {
    if ($done.ContainsKey([string]$r.Id)) { [void]$out.Add($done[[string]$r.Id]); continue }

    $link = ($r.Link -replace '^http://', 'https://')
    $row = [pscustomobject]@{
        Id          = [string]$r.Id
        Name        = [string]$r.Name
        Link        = $link
        Permalink   = ''
        Amount      = ''
        Currency    = ''
        Verdict     = 'unknown'
        CheckoutUrl = ''
        Note        = ''
    }

    $html = ''
    for ($i = 0; $i -le $Retries; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $link -UseBasicParsing -TimeoutSec 30 -MaximumRedirection 5 `
                        -Headers @{ 'User-Agent' = $cfg.http.userAgent }
            $html = $resp.Content
            if ($resp.StatusCode -ne 200) { $row.Note = "HTTP $($resp.StatusCode)" }
            break
        } catch {
            $row.Note = "ERR $($_.Exception.Message)"
            Start-Sleep -Seconds (5 * ($i + 1))
        }
    }

    if ($html) {
        $isGumroad = ($link -match 'gumroad\.com')
        if (-not $isGumroad) { $row.Note = ($row.Note + ' non-gumroad store front').Trim() }
        $m = [regex]::Match($html, 'product:price:amount"\s+content="([^"]*)"')
        if ($m.Success) { $row.Amount = $m.Groups[1].Value }

        $m = [regex]::Match($html, 'product:price:currency"\s+content="([^"]*)"')
        if ($m.Success) { $row.Currency = $m.Groups[1].Value }

        if (-not $row.Amount) {
            # fallback: some pages only expose the cents value in their data blob
            $m = [regex]::Match($html, '"price_cents"\s*:\s*(\d+)')
            if ($m.Success) { $row.Amount = ([double]$m.Groups[1].Value / 100).ToString('0.00') }
        }

        $m = [regex]::Match($html, '"permalink"\s*:\s*"([^"]+)"')
        if ($m.Success) { $row.Permalink = $m.Groups[1].Value }
        if (-not $row.Permalink) {
            $m = [regex]::Match($link, '/l/([^/?#]+)')
            if ($m.Success) { $row.Permalink = $m.Groups[1].Value }
        }
        if ($row.Permalink) {
            $row.CheckoutUrl = "https://gumroad.com/checkout?product=$($row.Permalink)"
        } else {
            $row.CheckoutUrl = $link
            $row.Note = ($row.Note + ' no-permalink').Trim()
        }

        $isZero = $false
        if ($row.Amount -ne '') {
            $parsedAmount = 0.0
            if ([double]::TryParse($row.Amount, [ref]$parsedAmount)) { $isZero = ($parsedAmount -eq 0) }
        }
        if ($isZero) { $row.Verdict = 'free' }
        elseif ($row.Amount -ne '') { $row.Verdict = 'paid' }
        else { $row.Verdict = 'unknown' }
    }

    [void]$out.Add($row)
    [void](Write-JsonList -Path $paths.gumroadPrices -Items @($out))

    $tag = switch ($row.Verdict) { 'free' { 'FREE ' } 'paid' { 'PAID ' } default { '???? ' } }
    Write-Host ("{0} {1,8} {2,-4} {3}" -f $tag, $row.Amount, $row.Currency, $row.Name)
    Start-Sleep -Milliseconds $DelayMilliseconds
}

[void](Write-JsonList -Path $paths.gumroadPrices -Items @($out))
$all = @($out)
Write-Host ''
Write-Host ("Probed {0} products: {1} free, {2} paid, {3} unknown." -f $all.Count,
    @($all | Where-Object { $_.Verdict -eq 'free' }).Count,
    @($all | Where-Object { $_.Verdict -eq 'paid' }).Count,
    @($all | Where-Object { $_.Verdict -eq 'unknown' }).Count)
Write-Host ("Wrote {0}" -f $paths.gumroadPrices)
Write-Host ''
Write-Host ' Next: scripts\gumroad-next.ps1   (then the browser checkout, one at a time)'
