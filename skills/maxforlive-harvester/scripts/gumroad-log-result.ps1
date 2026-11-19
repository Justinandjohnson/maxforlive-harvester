#requires -Version 5.1
<#
  gumroad-log-result.ps1 - append one outcome to the Gumroad ledger.

  The ledger (gumroad-results.json) is the only memory of what happened to a
  product, and it is written after EVERY item so a crashed browser, an expired
  login or a kill -9 loses nothing. Re-logging the same Id replaces its entry,
  which makes the loop idempotent.

  Outcomes (use exactly these strings so later passes can filter):
      free-purchased   checked out at a 0.00 total, download reached
      installed        payload installed into the User Library
      manual           .alp pack, needs a drag into Live
      paid             totals more than 0 - NOT bought, price recorded
      blocked-login    order went through but the download needs an account login
      blocked-payment  checkout demanded card details - abandoned
      blocked-price    the cart total was not 0.00 at submit time - abandoned
      no-link          no store front link on the page
      error            anything else, see -Note

  Usage:
      scripts\gumroad-log-result.ps1 -Id 17299 -Outcome paid -Price 5.49 -Note 'cart total at checkout'
      scripts\gumroad-log-result.ps1 -Id 17299 -Outcome free-purchased
#>

[CmdletBinding()]
param(
    [string]$Config,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)]
    [ValidateSet('free-purchased', 'installed', 'manual', 'paid', 'blocked-login', 'blocked-payment', 'blocked-price', 'no-link', 'error')]
    [string]$Outcome,
    [string]$Name = '',
    [string]$Link = '',
    [string]$Price = '',
    [string]$Note = '',
    [string]$Payload = ''      # path of the downloaded file, if any
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$cfg   = Get-M4LConfig -Config $Config -Quiet
$paths = Get-M4LPaths -Config $cfg

# Fill name/link/price from what earlier passes already know.
if ((-not $Name -or -not $Link) -and (Test-Path -LiteralPath $paths.gumroadPrices)) {
    $priceRows = Read-JsonList -Path $paths.gumroadPrices
    $hit = @($priceRows | Where-Object { [string]$_.Id -eq $Id }) | Select-Object -First 1
    if ($hit) {
        if (-not $Name) { $Name = [string](Get-Prop $hit 'Name' '') }
        if (-not $Link) { $Link = [string](Get-Prop $hit 'Link' '') }
        if (-not $Price) { $Price = [string](Get-Prop $hit 'Amount' '') }
    }
}

$ledger = @()
if (Test-Path -LiteralPath $paths.gumroadLedger) { $ledger = Read-JsonList -Path $paths.gumroadLedger }
$before = $ledger.Count

$kept = New-Object System.Collections.ArrayList
foreach ($e in $ledger) {
    if ([string]$e.Id -ne $Id) { [void]$kept.Add($e) }
}
[void]$kept.Add([pscustomobject]@{
    Id       = $Id
    Name     = $Name
    Link     = $Link
    Outcome  = $Outcome
    Price    = $Price
    Payload  = $Payload
    Note     = $Note
    LoggedAt = (Get-Date -Format 'o')
})

$count = Write-JsonList -Path $paths.gumroadLedger -Items @($kept)

Write-Host ("logged {0} -> {1}  (ledger {2} -> {3} entries, verified)" -f $Id, $Outcome, $before, $count)
if ($Outcome -eq 'paid') { Write-Host ("  recorded as PAID at {0} - nothing was purchased." -f $(if ($Price) { $Price } else { 'unknown price' })) }
if ($Outcome -like 'blocked-*') { Write-Host "  needs a human; it will not be retried automatically." }
