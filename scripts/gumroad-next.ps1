#requires -Version 5.1
<#
  gumroad-next.ps1 - what to open in the browser next.

  Cross-references the three Gumroad files and prints the work queue for the
  manual/browser step:

      gumroad-links.json    which store front page belongs to which device
      gumroad-prices.json   the price the product page advertises
      gumroad-results.json  what already happened

  It performs NO purchasing and opens NO window. It exists so the browser loop
  stays one-product-at-a-time and always resumes where it stopped.

  Usage:
      scripts\gumroad-next.ps1             # next free candidate
      scripts\gumroad-next.ps1 -All        # every unprocessed candidate
      scripts\gumroad-next.ps1 -Paid       # show the ones that were NOT free
#>

[CmdletBinding()]
param(
    [string]$Config,
    [switch]$All,
    [switch]$Paid,
    [int]$Limit = 1
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg   = Get-M4LConfig -Config $Config -Quiet
$paths = Get-M4LPaths -Config $cfg

foreach ($f in @($paths.gumroadLinks, $paths.gumroadPrices)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Host "Missing $f"
        Write-Host 'Run scripts\gumroad-discover.ps1 then scripts\gumroad-price-probe.ps1 first.'
        exit 1
    }
}

$prices = Read-JsonList -Path $paths.gumroadPrices
$ledger = @()
if (Test-Path -LiteralPath $paths.gumroadLedger) { $ledger = Read-JsonList -Path $paths.gumroadLedger }

$handled = @{}
foreach ($e in $ledger) { $handled[[string]$e.Id] = [string]$e.Outcome }

if ($Paid) {
    $items = @($prices | Where-Object { $_.Verdict -eq 'paid' })
    Write-Host ''
    Write-Host ("Paid - never bought ({0}):" -f $items.Count)
    foreach ($i in $items) {
        $st = if ($handled.ContainsKey([string]$i.Id)) { $handled[[string]$i.Id] } else { 'not processed' }
        Write-Host ("  {0,-8} {1,8} {2}  [{3}]  {4}" -f $i.Id, $i.Amount, $i.Name, $st, $i.Link)
    }
    Write-Host ''
    exit 0
}

$candidates = @($prices | Where-Object {
        $_.Verdict -eq 'free' -and -not $handled.ContainsKey([string]$_.Id)
    })

if ($candidates.Count -eq 0) {
    Write-Host 'Nothing left to check out.'
    Write-Host 'Either the ledger already covers every free product, or the probe found none.'
    exit 0
}

$take = if ($All) { $candidates.Count } else { $Limit }

Write-Host ''
Write-Host ("{0} free candidates, {1} not yet processed." -f @($prices | Where-Object { $_.Verdict -eq 'free' }).Count, $candidates.Count)
Write-Host ''
$i = 0
foreach ($c in ($candidates | Select-Object -First $take)) {
    $i++
    Write-Host ("[{0}] {1}  ({2})" -f $i, $c.Name, $c.Id)
    Write-Host ("    product page : {0}" -f $c.Link)
    Write-Host ("    checkout     : {0}" -f $c.CheckoutUrl)
    Write-Host ("    listed price : {0} {1}" -f $(if ($c.Amount) { $c.Amount } else { '?' }), $c.Currency)
    Write-Host ''
}

Write-Host ' Before submitting ANY checkout, confirm the cart Total is 0.00:'
Write-Host '   - listed price is NOT the total'
Write-Host '   - pay-what-you-want ("$0+") products often default to a number above zero'
Write-Host '   - if the total is above 0, log it as paid and move on'
Write-Host ''
Write-Host ' After the download:'
Write-Host '   scripts\finish-item.ps1 -Name "<device name>" -Since <iso time> -Expect "<substring>"'
Write-Host '   scripts\gumroad-log-result.ps1 -Id <id> -Outcome free-purchased'
Write-Host ''
