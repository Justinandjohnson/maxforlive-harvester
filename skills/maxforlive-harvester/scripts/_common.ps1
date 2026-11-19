#requires -Version 5.1
<#
  _common.ps1 - shared helpers for the Max for Live harvester.

  Dot-source it from any sibling script:

      . (Join-Path $PSScriptRoot '_common.ps1')

  Nothing in this file is machine specific. Every path comes from config.json,
  and config.json is produced by detect-library.ps1 on first run.
#>

$ErrorActionPreference = 'Continue'

# The directory above scripts/ holds config.json, state and work output.
$script:M4LScriptDir = $PSScriptRoot
$script:M4LRoot      = Split-Path -Parent $PSScriptRoot

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #

function Get-M4LDefaults {
    return [ordered]@{
        # Filled in by detect-library.ps1. Empty means "not configured yet".
        userLibrary    = ''
        # Where the browser drops downloads. Default resolves to the OS folder.
        downloadsDir   = ''
        # Harvest working state: queue, ledger, downloads, logs.
        workDir        = ''
        # Sub-folder created under "<UserLibrary>/Max for Live Devices/".
        collection     = 'Harvester'
        # Buyer email for FREE Gumroad checkouts. Never used for anything else.
        buyerEmail     = ''

        pacing         = [ordered]@{
            startDelay            = 3.0   # seconds between requests on a cold start
            minDelay              = 2.0
            maxDelay              = 120.0
            backoffFactor         = 1.6   # multiply the delay on HTTP 1015
            throttleRetryFactor   = 2.0   # wait this multiple of the delay before retrying the same item
            speedUpAfter          = 8     # consecutive successes before speeding up
            speedUpFactor         = 0.9
            maxRuntimeMinutes     = 600
        }

        http           = [ordered]@{
            curlPath  = 'curl.exe'
            userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
            requestTimeoutSeconds = 120
        }

        gumroad        = [ordered]@{
            # Hard ceiling. Anything that totals more than this is never bought.
            maxFreeTotal   = 0.0
            currency       = 'USD'
            # Candidate store fronts to look for on a device page when the file
            # is gated. First match wins.
            storeFronts    = @('gumroad.com', 'lemonsqueezy', 'ko-fi', 'itch.io', 'payhip')
        }
    }
}

function Expand-M4LPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    if ($p.StartsWith('~')) {
        $home_ = [Environment]::GetFolderPath('UserProfile')
        $p = $home_ + $p.Substring(1)
    }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    # Allow %VAR% style in addition to $env:VAR
    try { $p = $ExecutionContext.InvokeCommand.ExpandString($p) } catch { }
    return $p
}

function Find-M4LConfigFile {
    param([string]$ConfigPath)

    $candidates = New-Object System.Collections.ArrayList
    if ($ConfigPath) { [void]$candidates.Add($ConfigPath) }
    if ($env:M4L_HARVEST_CONFIG) { [void]$candidates.Add($env:M4L_HARVEST_CONFIG) }
    [void]$candidates.Add((Join-Path $script:M4LRoot 'config.json'))

    foreach ($c in $candidates) {
        $c = Expand-M4LPath $c
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Get-DefaultDownloadsDir {
    # Ask the OS, do not assume ~/Downloads: it can be relocated (and on
    # Windows it is very often redirected into OneDrive or a second drive).
    $known = [Environment]::GetFolderPath('UserProfile')
    $profileDownloads = Join-Path $known 'Downloads'
    if (Test-Path -LiteralPath $profileDownloads) { return $profileDownloads }
    return $profileDownloads
}

function Get-M4LConfig {
    <#
      Loads config.json, merging it over the defaults so a partial config works.
      Returns a PSCustomObject with resolved, expanded paths.
    #>
    param(
        [string]$ConfigPath,
        [switch]$Quiet
    )

    $defaults = Get-M4LDefaults
    $file = Find-M4LConfigFile -ConfigPath $ConfigPath
    $loaded = $null

    if ($file) {
        try {
            $raw = Get-Content -LiteralPath $file -Raw
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $loaded = $raw | ConvertFrom-Json
            }
        } catch {
            throw "config.json at '$file' is not valid JSON: $($_.Exception.Message)"
        }
    } elseif (-not $Quiet) {
        Write-Warning "No config.json found (looked for $(Join-Path $script:M4LRoot 'config.json')). Run scripts\detect-library.ps1 first. Using defaults."
    }

    $cfg = [ordered]@{}
    foreach ($k in $defaults.Keys) { $cfg[$k] = $defaults[$k] }

    if ($loaded) {
        foreach ($p in $loaded.PSObject.Properties) {
            $name = $p.Name
            if (-not $cfg.Contains($name)) { $cfg[$name] = $p.Value; continue }
            $default = $cfg[$name]
            if ($default -is [System.Collections.Specialized.OrderedDictionary] -and $p.Value.GetType().Name -eq 'PSCustomObject') {
                # merge one level of nested settings so a partial pacing block works
                foreach ($sp in $p.Value.PSObject.Properties) { $default[$sp.Name] = $sp.Value }
            } else {
                $cfg[$name] = $p.Value
            }
        }
    }

    $result = [pscustomobject]@{}
    foreach ($k in $cfg.Keys) {
        if ($cfg[$k] -is [System.Collections.Specialized.OrderedDictionary]) {
            $sub = [pscustomobject]@{}
            foreach ($sk in $cfg[$k].Keys) { $sub | Add-Member -NotePropertyName $sk -NotePropertyValue $cfg[$k][$sk] }
            $result | Add-Member -NotePropertyName $k -NotePropertyValue $sub
        } else {
            $result | Add-Member -NotePropertyName $k -NotePropertyValue $cfg[$k]
        }
    }

    $result | Add-Member -NotePropertyName configFile -NotePropertyValue $file -Force
    $result | Add-Member -NotePropertyName root       -NotePropertyValue $script:M4LRoot -Force

    $result.userLibrary  = Expand-M4LPath $result.userLibrary
    $result.downloadsDir = Expand-M4LPath $(if ($result.downloadsDir) { $result.downloadsDir } else { Get-DefaultDownloadsDir })
    $result.workDir      = Expand-M4LPath $(if ($result.workDir) { $result.workDir } else { Join-Path $script:M4LRoot '.work' })

    return $result
}

function Save-M4LConfig {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ConfigPath
    )

    $target = if ($ConfigPath) { Expand-M4LPath $ConfigPath } else { Join-Path $script:M4LRoot 'config.json' }
    $out = [ordered]@{}
    foreach ($p in $Config.PSObject.Properties) {
        if ($p.Name -in @('configFile', 'root')) { continue }
        $out[$p.Name] = $p.Value
    }
    $dir = Split-Path -Parent $target
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ConvertTo-Json -InputObject $out -Depth 6
    [System.IO.File]::WriteAllText($target, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $target
}

function Get-M4LPaths {
    <#
      Returns the concrete folders used by the pipeline. Creates workDir and
      the download cache but never creates anything inside the User Library.
    #>
    param($Config)

    $paths = [ordered]@{
        root          = $Config.root
        workDir       = $Config.workDir
        downloads     = Join-Path $Config.workDir 'downloads'
        queueFile     = Join-Path $Config.workDir 'queue.json'
        stateFile     = Join-Path $Config.workDir 'state.json'
        devicesFile   = Join-Path $Config.workDir 'devices.json'
        catalogFile   = Join-Path $Config.workDir 'catalog-data.json'
        catalogMd     = Join-Path $Config.workDir 'CATALOG.md'
        runLog        = Join-Path $Config.workDir 'run.log'
        cookieJar     = Join-Path $Config.workDir 'cookies.txt'
        gumroadLinks  = Join-Path $Config.workDir 'gumroad-links.json'
        gumroadPrices = Join-Path $Config.workDir 'gumroad-prices.json'
        gumroadLedger = Join-Path $Config.workDir 'gumroad-results.json'
    }

    foreach ($k in @('workDir', 'downloads')) {
        if (-not (Test-Path -LiteralPath $paths[$k])) {
            New-Item -ItemType Directory -Force -Path $paths[$k] | Out-Null
        }
    }
    return [pscustomobject]$paths
}

function Get-UserLibraryStatus {
    param([string]$UserLibrary)

    if ([string]::IsNullOrWhiteSpace($UserLibrary)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'userLibrary is empty in config.json - run scripts\detect-library.ps1' }
    }
    $devices = Join-Path $UserLibrary 'Max for Live Devices'
    if (-not (Test-Path -LiteralPath $UserLibrary)) {
        return [pscustomobject]@{ Ok = $false; Reason = "User Library path does not exist: $UserLibrary" }
    }
    if (-not (Test-Path -LiteralPath $devices)) {
        return [pscustomobject]@{ Ok = $false; Reason = "No 'Max for Live Devices' folder inside $UserLibrary - is this really the User Library?" }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'ok'; DevicesDir = $devices }
}

# --------------------------------------------------------------------------- #
# Logging and naming
# --------------------------------------------------------------------------- #

function Write-M4LLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$LogFile,
        [switch]$Echo
    )

    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($LogFile) {
        $dir = Split-Path -Parent $LogFile
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
    if ($Echo -or -not $LogFile) { Write-Host $line }
}

function ConvertTo-SafeName {
    <#
      Produces a file-system safe leaf name. Keeps spaces, drops the
      characters Windows refuses, and caps the length so long device names
      plus a path do not blow the MAX_PATH budget.
    #>
    param(
        [string]$Name,
        [int]$MaxLength = 90
    )

    if ($null -eq $Name) { return '' }
    $s = [string]$Name
    $s = $s -replace '&amp;', '&'
    $s = $s -replace '&quot;', "'"
    $s = $s -replace '&#0?39;', "'"
    $s = $s -replace '<[^>]+>', ' '
    $s = $s -replace '[\\/:*?"<>|]', ''
    $s = $s -replace '[\x00-\x1f]', ''
    $s = $s -replace '\s+', ' '
    $s = $s.Trim().TrimEnd('.')
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).TrimEnd() }
    if (-not $s) { $s = 'unnamed' }
    return $s
}

# --------------------------------------------------------------------------- #
# File signatures / validation
# --------------------------------------------------------------------------- #

function Get-FileSignature {
    <#
      Returns 'ampf', 'zip', 'gz' or 'other' plus the size, without loading a
      multi-megabyte file into memory.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [pscustomobject]@{ Path = $Path; Kind = 'other'; Size = 0; Header = '' }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }

    $info = Get-Item -LiteralPath $Path
    $result.Size = $info.Length
    if ($info.Length -lt 2) { return $result }

    $bytes = New-Object byte[] 4
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { [void]$fs.Read($bytes, 0, 4) } finally { $fs.Close() }
    } catch { return $result }

    $result.Header = (($bytes | ForEach-Object { [char]$_ }) -join '')

    if ($bytes[0] -eq 0x61 -and $bytes[1] -eq 0x6D -and $bytes[2] -eq 0x70 -and $bytes[3] -eq 0x66) {
        $result.Kind = 'ampf'      # .amxd
    } elseif ($bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B) {
        $result.Kind = 'zip'
    } elseif ($bytes[0] -eq 0x1F -and $bytes[1] -eq 0x8B) {
        $result.Kind = 'gz'
    }
    return $result
}

function Test-AmpfFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ((Get-FileSignature -Path $Path).Kind -eq 'ampf')
}

function Test-M4LResponseBody {
    <#
      Classifies a small download.php response body. maxforlive.com answers a
      failed download with a short plain-text string, which is easy to mistake
      for a corrupt device. Returns 'throttled', 'notfound' or 'unknown'.
    #>
    param([Parameter(Mandatory = $true)][string]$Text)

    if ($Text -match '1015|rate limit|too many requests|429') { return 'throttled' }
    if ($Text -match 'not\s*found|removed|no longer available')  { return 'notfound' }
    return 'unknown'
}

# --------------------------------------------------------------------------- #
# JSON helpers (PowerShell 5.1 safe)
# --------------------------------------------------------------------------- #

function Read-JsonList {
    <#
      Reads a JSON file that should contain an array and ALWAYS returns a flat
      Object[]. Assign the result WITHOUT wrapping it in @() again:

          $items = Read-JsonList -Path $f      # right
          $items = @(Read-JsonList -Path $f)   # WRONG: one-element nested array

      PowerShell 5.1 turns a 1-element pipeline result into the element itself
      and some callers then re-wrap it, which is how a list of 300 devices
      silently becomes a list of one array.

      Also: NEVER pipe the call directly ("Read-JsonList ... | Where-Object").
      The function deliberately emits the array as a single object, so the
      filter would receive one array instead of its elements and match nothing.
      Assign first, then pipe the variable.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $empty = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return ,$empty.ToArray() }

    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return ,$empty.ToArray() }

    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { throw "Cannot parse JSON at '$Path': $($_.Exception.Message)" }
    if ($null -eq $parsed) { return ,$empty.ToArray() }

    $list = New-Object System.Collections.ArrayList
    foreach ($item in @($parsed)) {
        if ($null -eq $item) { continue }
        if ($item -is [System.Array]) {
            foreach ($sub in $item) { if ($null -ne $sub) { [void]$list.Add($sub) } }
        } else {
            [void]$list.Add($item)
        }
    }
    return ,$list.ToArray()
}

function Write-JsonList {
    <#
      Writes a flat JSON array and verifies the element count round-trips.
      Refuses to leave a truncated file behind.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Items,
        [int]$Depth = 8
    )

    $list = @($Items)
    if ($list.Count -eq 0) {
        $json = '[]'
    } else {
        # -InputObject keeps a 1-element array an array (piping would unwrap it).
        $json = ConvertTo-Json -InputObject $list -Depth $Depth
        if (-not $json.TrimStart().StartsWith('[')) { $json = "[`n$json`n]" }
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force

    $check = Read-JsonList -Path $Path
    if ($check.Count -ne $list.Count) {
        throw "JSON round-trip failed for '$Path': wrote $($list.Count) items, read back $($check.Count)."
    }
    return $list.Count
}

function Read-JsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Write-JsonObject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object,
        [int]$Depth = 8
    )
    $json = ConvertTo-Json -InputObject $Object -Depth $Depth
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Prop {
    <#
      Safe property read for PSCustomObjects coming from JSON of unknown shape.
    #>
    param($Object, [string]$Name, $Default = '')

    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

# --------------------------------------------------------------------------- #
# Adaptive pacing
# --------------------------------------------------------------------------- #

function New-M4LState {
    param($Config)

    return [pscustomobject]@{
        delaySeconds   = [double]$Config.pacing.startDelay
        minDelay       = [double]$Config.pacing.minDelay
        maxDelay       = [double]$Config.pacing.maxDelay
        consecutiveOk  = 0
        consecutiveErr = 0
        throttleEvents = 0
        lastRun        = $null
        startedAt      = $null
        note           = 'Learned pacing. Delete this file to start over at startDelay.'
    }
}

function Get-M4LState {
    <#
      Loads state.json, or builds a fresh one. Also repairs a state file that
      was written by an older config with a different min/max.
    #>
    param($Config, [string]$Path)

    $state = Read-JsonObject -Path $Path
    if ($null -eq $state) { return (New-M4LState -Config $Config) }

    $fresh = New-M4LState -Config $Config
    foreach ($p in $fresh.PSObject.Properties) {
        if ($null -eq $state.PSObject.Properties[$p.Name]) {
            $state | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
    $state.minDelay = [double]$Config.pacing.minDelay
    $state.maxDelay = [double]$Config.pacing.maxDelay
    if ([double]$state.delaySeconds -lt $state.minDelay) { $state.delaySeconds = $state.minDelay }
    if ([double]$state.delaySeconds -gt $state.maxDelay) { $state.delaySeconds = $state.maxDelay }
    return $state
}

function Update-M4LPacing {
    <#
      The heart of the rate-limit handling.

      'ok'        a good response (device file OR a clean "not found") proves we
                  are not being throttled. After speedUpAfter of those in a row,
                  shave speedUpFactor off the delay, never under minDelay.
      'throttled' HTTP 1015. Multiply the delay by backoffFactor, capped at
                  maxDelay, and reset the success streak.
      'error'     transient/unknown. Reset the streak but do not shorten.

      Returns the wait to use before the NEXT request, in seconds.
    #>
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][ValidateSet('ok', 'throttled', 'error')][string]$Outcome,
        [Parameter(Mandatory = $true)]$Config
    )

    $p = $Config.pacing

    switch ($Outcome) {
        'ok' {
            $State.consecutiveOk  = [int]$State.consecutiveOk + 1
            $State.consecutiveErr = 0
            if ($State.consecutiveOk -ge [int]$p.speedUpAfter) {
                $State.delaySeconds = [Math]::Max([double]$p.minDelay, [double]$State.delaySeconds * [double]$p.speedUpFactor)
                $State.consecutiveOk = 0
            }
        }
        'throttled' {
            $State.throttleEvents = [int]$State.throttleEvents + 1
            $State.consecutiveErr = [int]$State.consecutiveErr + 1
            $State.consecutiveOk  = 0
            $State.delaySeconds   = [Math]::Min([double]$p.maxDelay, [Math]::Max([double]$p.minDelay, [double]$State.delaySeconds * [double]$p.backoffFactor))
        }
        'error' {
            $State.consecutiveErr = [int]$State.consecutiveErr + 1
            $State.consecutiveOk  = 0
        }
    }

    $State.lastRun = (Get-Date -Format 'o')
    if ($Outcome -eq 'throttled') {
        return [Math]::Min([double]$p.maxDelay, [double]$State.delaySeconds * [double]$p.throttleRetryFactor)
    }
    return [double]$State.delaySeconds
}

function Start-M4LWait {
    param(
        [Parameter(Mandatory = $true)][double]$Seconds,
        [string]$Reason = ''
    )
    if ($Seconds -le 0) { return }
    if ($Reason) { Write-Host ("  waiting {0:N1}s ({1})" -f $Seconds, $Reason) }
    Start-Sleep -Milliseconds ([int]($Seconds * 1000))
}

# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #

function Get-CurlPath {
    param($Config)

    $candidate = $Config.http.curlPath
    if ($candidate -and (Test-Path -LiteralPath (Expand-M4LPath $candidate))) { return (Expand-M4LPath $candidate) }
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command 'curl' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "curl was not found. curl ships with Windows 10+ and macOS; set http.curlPath in config.json if it lives somewhere unusual."
}

# --------------------------------------------------------------------------- #
# Calling sibling scripts
# --------------------------------------------------------------------------- #

function Invoke-M4LScript {
    <#
      Runs a sibling script in a CHILD PowerShell and returns its output and
      exit code.

      Do not use "& script.ps1" for this. A script that calls "exit 3" invoked
      in-process does not just return 3 - it terminates the calling session, so
      the caller's remaining code silently never runs. A child process gives a
      real exit code and cannot take the worker down with it.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptName,
        [string[]]$Arguments = @()
    )

    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Missing sibling script: $scriptPath" }

    $exe = 'powershell.exe'
    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) { $exe = 'pwsh' }
    try {
        $hostPath = (Get-Process -Id $PID -ErrorAction Stop).Path
        if ($hostPath -and (Split-Path -Leaf $hostPath) -match '^(powershell|pwsh)(\.exe)?$') { $exe = $hostPath }
    } catch { }

    $output = & $exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1
    return [pscustomobject]@{
        Output   = @($output | ForEach-Object { [string]$_ })
        ExitCode = $LASTEXITCODE
    }
}

# --------------------------------------------------------------------------- #
# Browser download completion guard
# --------------------------------------------------------------------------- #

function Wait-M4LDownload {
    <#
      Watches a browser download folder and reports honestly.

      COMPLETE      a finished .amxd/.zip/.alp/... file appeared
      COMPLETE-TMP  a browser partial (.crdownload/.part/.tmp) stopped growing
                    AND already has a valid archive header - it is finished but
                    the browser never renamed it
      STALLED       a partial exists and is not growing: a Save/Open dialog is
                    almost certainly waiting for a human click
      NONE          nothing appeared within the timeout

      Never assume success from "no error". Nothing about a browser download is
      atomic, and a stalled dialog looks exactly like a download in progress.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DownloadDir,
        [int]$TimeoutSeconds = 90,
        [datetime]$Since = (Get-Date).AddMinutes(-5),
        [string[]]$Kinds = @('.zip', '.amxd', '.alp', '.rar', '.7z', '.gz', '.maxpat'),
        [string]$Expect = '',
        [switch]$Quiet
    )

    $partialExt = @('.crdownload', '.part', '.tmp', '.download', '.partial')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    function Get-Partials {
        Get-ChildItem -LiteralPath $DownloadDir -File -ErrorAction SilentlyContinue |
            Where-Object { $partialExt -contains $_.Extension.ToLower() -or $_.Name -like '*crdownload*' }
    }
    function Get-Finished {
        Get-ChildItem -LiteralPath $DownloadDir -File -ErrorAction SilentlyContinue |
            Where-Object {
                $_.LastWriteTime -ge $Since -and
                $Kinds -contains $_.Extension.ToLower() -and
                ($Expect -eq '' -or $_.Name -like "*$Expect*")
            }
    }

    while ((Get-Date) -lt $deadline) {
        $partials = @(Get-Partials)
        if ($partials.Count -eq 0) {
            $done = @(Get-Finished)
            if ($done.Count -gt 0) {
                $best = $done | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                return [pscustomobject]@{ State = 'COMPLETE'; File = $best.FullName; Size = $best.Length; Partial = $null }
            }
        } else {
            $p = $partials | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $size1 = $p.Length
            Start-Sleep -Seconds 3
            $p2 = Get-Item -LiteralPath $p.FullName -ErrorAction SilentlyContinue
            if (-not $p2) { continue }          # renamed mid-check, loop again
            if ($size1 -eq $p2.Length) {
                $sig = Get-FileSignature -Path $p2.FullName
                if ($sig.Kind -eq 'ampf' -or $sig.Kind -eq 'zip') {
                    return [pscustomobject]@{ State = 'COMPLETE-TMP'; File = $p2.FullName; Size = $p2.Length; Partial = $p2.FullName }
                }
                return [pscustomobject]@{ State = 'STALLED'; File = $p2.FullName; Size = $p2.Length; Partial = $p2.FullName }
            }
            if (-not $Quiet) {
                Write-Host ("  download in progress: {0} ({1} KB)" -f $p.Name, [math]::Round($p2.Length / 1KB))
            }
        }
        Start-Sleep -Seconds 3
    }

    return [pscustomobject]@{ State = 'NONE'; File = $null; Size = 0; Partial = $null }
}

