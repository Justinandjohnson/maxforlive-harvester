---
name: maxforlive-harvester
description: Find, download, verify and install Max for Live (.amxd) devices and packs into Ableton Live, including free Gumroad checkouts, with adaptive rate-limit handling and device categorisation. Use when bulk-adding M4L devices or harvesting maxforlive.com.
metadata:
  origin: community
---

# Max for Live Harvester

Bulk harvest Max for Live devices from maxforlive.com, validate them, place them
where Live actually looks, complete the FREE checkout for devices the author
moved to Gumroad, and produce a categorised catalogue of what you now own.

Everything is parameterised: **no path in this skill assumes a particular user,
OS layout, Documents folder, or Live version.** The first script reads Live's own
indexer log to find the User Library. Use it for any machine and any Live 10/11/12
install.

---

## 1. Hard rules (read before touching anything)

1. **Never spend money.** Only 0.00-total checkouts are in scope. If a cart total
   is above zero, abandon it and record the price as `paid`. Never enter payment
   details, ever - not even for a "free" product that asks for a card.
2. **Never take focus.** Do not open windows, raise dialogs, launch Live, or
   activate an app while the user is working. A GUI window steals focus from
   whatever they are doing. All browser work is headless/automated or handed to
   the operator; all long work runs as a background job.
3. **Never run a long job in the foreground.** Downloads and crawls can run for
   hours. Start them as background jobs (your harness's job runner, or
   `Start-Process -WindowStyle Hidden -RedirectStandardOutput <log>`), then poll
   `monitor.ps1` / `run.log`. Never leave a console waiting for a keypress.
4. **One worker at a time.** All parallel agents share a single browser session;
   two workers collide on tabs and corrupt each other's checkout state. Serialise.
5. **Never replace control-surface or libusb files** as part of a device install.
   If a downloaded pack ships a `Remote Scripts` folder, a `.py` for Push, or a
   libusb DLL, stop: that is an Ableton installation change, not a device
   install. Report it and let the user decide. `install-m4l.ps1` only ever writes
   inside `<UserLibrary>/Max for Live Devices` and `<UserLibrary>/Presets`.
6. **Never claim success you did not verify.** A download that "seemed to work"
   is a 200-byte "File not found" string or a stalled Save dialog until the first
   four bytes say otherwise. Check magic bytes. Check the library.

---

## 2. Install

Copy the `scripts/` folder and `config.example.json` anywhere (the repo root is
fine). Then:

```powershell
# from the repo root
Copy-Item config.example.json config.json
.\scripts\detect-library.ps1                 # writes userLibrary into config.json
```

The skill also works installed under an agent's skill directory
(`<skills>/maxforlive-harvester/SKILL.md` + `scripts/`); scripts resolve
`config.json` next to the `scripts/` folder.

Requirements: PowerShell 5.1+ (Windows) or pwsh 7 (macOS/Linux); `curl` (ships
with Windows 10+ and macOS); Ableton Live installed and started at least once.

### Config reference (`config.json`)

| Key | Meaning |
| --- | --- |
| `userLibrary` | Absolute path to the Live User Library. Set by `detect-library.ps1`. |
| `downloadsDir` | Where the browser drops files. Defaults to the OS Downloads folder. |
| `workDir` | Queue, ledger, payload cache, logs, quarantine. Defaults to `<repo>/.work`. |
| `collection` | Sub-folder created under `Max for Live Devices/`. |
| `buyerEmail` | Email used for FREE Gumroad checkouts. Used for nothing else. **Leave empty until the user supplies it — see the rule below.** |
| `pacing.*` | Rate-limit controller (see section 5). |
| `http.curlPath`, `http.userAgent` | curl location and the browser UA that gets past Cloudflare. |
| `gumroad.maxFreeTotal` | Ceiling. Keep at `0`. |
| `gumroad.storeFronts` | Store fronts scanned for on a gated device page. |

### ASK THE USER FOR THEIR EMAIL — never assume one

`buyerEmail` ships **empty on purpose**. Before the first Gumroad checkout in any
session:

1. If `config.json:buyerEmail` is empty, **stop and ask the user for their email
   address**. Ask in one plain question. Do not proceed to checkout without it.
2. Once given, write it to `config.json` and use it for this user only.
3. Never hardcode an email into a script, a commit, an example file, or this
   document. Never reuse an email found in a previous session, a config backup,
   git history, or another user's files.
4. Never invent, guess, or derive an address. An email is a real person's inbox.

The same rule applies to anything else personal: a postal address is sometimes
required by Gumroad for a $0 order — ask for it, do not fabricate one, and if the
user declines, mark that item `blocked` and move on.

---

## 3. First run: find the real User Library

```powershell
.\scripts\detect-library.ps1 -List        # every Live version with an indexer log
.\scripts\detect-library.ps1              # pick the newest, write config.json
.\scripts\detect-library.ps1 -LiveVersion 12.0.1 -Force   # target another version
.\scripts\detect-library.ps1 -UserLibrary "D:\Audio\Ableton\User Library" -Force
```

How detection works: Ableton writes an `Indexer.txt` per installed version, and
one line names the User Library:

```
%APPDATA%\Ableton\Live <VER>\Preferences\Indexer.txt      (Windows)
~/Library/Preferences/Ableton/Live <VER>/Indexer.txt      (macOS)
...
Configure: UserLibrary: 'C:\Users\me\OneDrive\Documents\Ableton\User Library' [User Library]
```

Take the LAST occurrence in the file (it is written once per index run) and use
that path.

**Why this matters:** `~/Documents` is routinely redirected into OneDrive,
Dropbox or another drive. A script that hard-codes `Documents\Ableton\User
Library` writes into a folder Live does not index: the install "succeeds", the
device never appears, and hours get wasted. `detect-library.ps1` warns loudly
when it finds a second library in `Documents` that Live is NOT using.

If no indexer log exists, start Live once and retry - or pass `-UserLibrary`
explicitly.

---

## 4. Inventory the catalogue

```powershell
.\scripts\list-devices.ps1 -Pages 3                    # 3 newest pages
.\scripts\list-devices.ps1 -Pages 0                    # every page (paced, slow)
.\scripts\list-devices.ps1 -Pages 20 -Type instrument  # instruments only
.\scripts\list-devices.ps1 -Pages 10 -Type midi        # midi effects
.\scripts\list-devices.ps1 -Pages 10 -Type audio       # audio effects
.\scripts\list-devices.ps1 -Pages 5 -Fresh             # start the inventory over
```

Writes `<workDir>/devices.json` (merged, resumable, one write per page).

List page shape:

```
https://maxforlive.com/library/index.php?by=any&sortby=dev_date_added&pc=<N>
```

* `pc` is **1-based**; the page links forward with `pc=<N+1>`, so "no `pc=N+1`
  in the HTML" means last page.
* `&type=instrument|midi|audio` filters by device kind.
* Each device is a `<div class="device-item">` block containing:
  * three `<span class="day">` spans = month, day, year of upload
  * `/library/device/<id>/<slug>` (the device link, also the anchor text = name+version)
  * `/profile/user/<author>`
  * `<div class="library-device-description">` - a *truncated teaser*, often with `<br />`
* Parse by splitting on the literal marker `device-item`. Use `-split`
  (regex), never `String.Split('device-item')`: `Split(char[])` would split on
  every character `d`,`e`,`v`,`i`,... and return thousands of fragments.

---

## 5. Build the queue

```powershell
.\scripts\build-queue.ps1
.\scripts\build-queue.ps1 -Type instrument -Since 2024-01-01
.\scripts\build-queue.ps1 -Take 50 -RebuildState
.\scripts\build-queue.ps1 -Only 17293,17294
```

Devices whose name already exists as an `.amxd` in the User Library are skipped
(marked `have`) unless `-IncludeHave`. Writes `<workDir>/queue.json`.

Statuses: `pending`, `downloaded`, `installed`, `have`, `gated`, `error`,
`manual`.

---

## 6. Download (the worker)

```powershell
.\scripts\run.ps1                              # until queue empty (config maxRuntime)
.\scripts\run.ps1 -MaxRuntimeMinutes 120 -Limit 40
.\scripts\run.ps1 -Install                     # download AND place into the library
.\scripts\run.ps1 -RetryErrors                 # error items back to pending
.\scripts\run.ps1 -StartDelay 5                # force a slower start this run
```

Background it for real runs:

```powershell
Start-Process -WindowStyle Hidden -FilePath powershell -ArgumentList `
  '-NoProfile','-ExecutionPolicy','Bypass','-File','.\scripts\run.ps1','-Install','-MaxRuntimeMinutes','600' `
  -RedirectStandardOutput ".\scripts-log.txt" -RedirectStandardError ".\scripts-err.txt"
.\scripts\monitor.ps1
```

### 6.1 The request that works

Downloads are a **POST**, not a GET:

```
POST https://maxforlive.com/download.php
     id=<device id>&submit=Download+Device
Referer: https://maxforlive.com/library/device/<id>/<slug>
```

* Use `curl`, not `.NET Invoke-WebRequest`: the .NET HTTP stack's TLS
  fingerprint gets a flat **403 from Cloudflare** while `curl.exe` on the same
  machine with the same headers succeeds.
* Send a browser User-Agent and use a cookie jar (`-c`/`-b`) across the run.
* Write the response body to a file and inspect the first bytes; do not trust
  status codes alone.

### 6.2 Validate before trusting a file

| First bytes | Meaning |
| --- | --- |
| `ampf` | a Max device (`.amxd`) |
| `PK` (0x50 0x4B) | a zip |
| `1f 8b` | gzip (rare; unpack before install) |
| anything else, body < 200 bytes | **not a file** - read it as text |

Small text bodies mean:

* `File not found` - the author removed it, or it now lives behind a store front
  -> status `gated` (this is where the Gumroad step starts).
* `error code: 1015` - **rate limited**, not missing. Retry; see below.

Treating 1015 as "not found" is the single biggest source of false negatives in
this workflow: hundreds of devices get marked dead that are perfectly fine.

### 6.3 Adaptive pacing (the important part)

Bursting gets you HTTP 429 with body `error code: 1015`. Once that happens,
*every* request fails the same way until the IP cools down.

The controller lives in `scripts/_common.ps1:Update-M4LPacing` and the learned
value persists in `<workDir>/state.json`, so a restart resumes at the safe rate
instead of starting a new burst:

* start at `startDelay` (3 s)
* on 1015: `delay *= backoffFactor` (1.6), capped at `maxDelay` (120 s), and the
  **same device is retried** after `delay * throttleRetryFactor` (2x)
* after `speedUpAfter` (8) consecutive good responses: `delay *= 0.9`, never
  below `minDelay` (2 s)
* a clean "File not found" counts as a good response - the server answered
* `error` responses reset the streak but do not shorten the delay

Observed behaviour: 3.0 s -> 4.8 s after one throttle, 2.7 s after eight clean
downloads. Delete `state.json` only if you deliberately want to start over.

---

## 7. Install

```powershell
.\scripts\install-m4l.ps1 -Path "<workDir>\downloads\Thing [123].amxd"
.\scripts\install-m4l.ps1 -Path "...\Pack [456].zip" -Name "Pack"
.\scripts\install-m4l.ps1 -Path ... -WhatIfOnly
```

Powered by `run.ps1 -Install`, or by `finish-item.ps1` for browser downloads.

Exit codes: `0` ok, `1` missing input, `2` invalid `.amxd`, `3` unsupported,
`4` `.alp` (manual), `5` unsafe zip entry.

### 7.1 Placement rules

| Payload | Destination |
| --- | --- |
| plain `.amxd`, no sidecars | `<UserLibrary>/Max for Live Devices/<Collection>/<Name>.amxd` |
| `.amxd` + sibling `.js` / `.html` / `.json` / images | `<UserLibrary>/Presets/Max MIDI Effect/<Name>/` (whole folder) |
| multi-device zip | `<UserLibrary>/Max for Live Devices/<Collection>/<Name>/` |
| `.alp` pack | **not installable by script** |

Sidecars are not optional: a device whose patch loads `engine.js` or an `.html`
UI only works when that file sits where the patch expects it. The Presets tree
keeps the folder together, which is why those devices go there.

### 7.2 Zip extraction

`Expand-Archive` fails on a large share of M4L zips (bit-7 filenames, absolute
paths, backslash separators, missing directory entries). Use:

```powershell
$zip = [System.IO.Compression.ZipFile]::OpenRead($path)
foreach ($e in $zip.Entries) {
    if ($e.FullName -match '(^|/)__MACOSX(/|$)') { continue }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $outPath, $true)
}
$zip.Dispose()
```

Notes: skip `__MACOSX`; skip entries ending in `/` (directories); reject `../`
and absolute paths (zip-slip); .NET Framework has **no**
`ExtractToDirectory` overload that overwrites, so the per-entry loop is also the
only re-runnable option.

### 7.3 Pack hygiene

M4L zips frequently ship the author's C++/Visual Studio tree (`Source/`, `x64/`,
`*.vcxproj`, `*.sln`, `*.suo`). Live's indexer throws errors on those and can
stall on a large tree, so `install-m4l.ps1` moves them to
`<workDir>/quarantine/<Name>/` before installing. The device does not need them
at runtime. Use `-KeepSourceTrees` to disable.

---

## 8. Make Live see it

Live watches the User Library with OS file events, so **a restart is normally
unnecessary** - the device appears within a second or two of the copy.

Confirm Live is indexing the folder you wrote to:

```powershell
Get-Content "$env:APPDATA\Ableton\Live 12.2.5\Preferences\Indexer.txt" -Tail 40 |
  Select-String 'UserLibrary|User Library'
```

If the device is not in the browser, right-click **User Library > Refresh
Browser** (Live 11/12: `Places > User Library > Refresh`). If it still is not
there, the library path is wrong - go back to section 3.

---

## 9. Free Gumroad checkouts

### 9.1 No Gumroad MCP can help

Every Gumroad MCP server in existence is **seller-side**: `gumroad.com/mcp`,
`rmarescu/gumroad-mcp`, `N-Graves/gumroad-mcp-server`. They authenticate with
the *user's own* `GUMROAD_ACCESS_TOKEN` and let a creator manage *their* products,
sales and licences. None of them can purchase or download *another creator's*
product, and using the user's seller token to try would be both useless and
wrong.

So the mechanism is browser automation, with the operator's own logged-in
session.

### 9.2 Find the product

```powershell
.\scripts\gumroad-discover.ps1        # scans gated devices for store front links
.\scripts\gumroad-price-probe.ps1     # reads product:price:amount + permalink
.\scripts\gumroad-next.ps1            # next free candidate, with its checkout URL
.\scripts\gumroad-next.ps1 -Paid      # what was too expensive to touch
```

The probe reads the product page metadata (`product:price:amount`,
`product:price:currency`, `"permalink":"..."`) and builds:

```
https://gumroad.com/checkout?product=<permalink>
```

### 9.3 The click that does not work

Modern Gumroad product pages are an **Inertia SPA**. Clicking "I want this!"
through automation silently does nothing - no error, no navigation, no cart. Do
not debug it; do not click it 20 times. Instead:

1. read the product permalink from the page (or from `gumroad-prices.json`),
2. navigate straight to `https://gumroad.com/checkout?product=<permalink>`.

The checkout page renders the real cart.

### 9.4 Checkout procedure, one product at a time

1. `gumroad-next.ps1` -> the product URL and checkout URL.
2. Open the **checkout** URL (not the product page).
3. Read the cart: line item, and the **Total**.
4. **Verify Total == 0.00 in the checkout's currency.** A product that reads
   "$0+" on the listing (pay-what-you-want) can default to a non-zero amount; a
   "$0" listing can carry a minimum. One observed case: a free-looking M4L
   device totalled **5.49** at checkout. Never submit anything above zero - log
   it as `paid` with the price and move on.
5. If a card field is demanded, abandon: log `blocked-payment`.
6. Enter **email only** if asked (from `config.json:buyerEmail`). Never card
   numbers, never a password, never an address unless the user provided one.
7. Submit, then take the download from `https://gumroad.com/d/<id>` (the
   receipt also lands there).
8. If the order completes but the receipt bounces to the Gumroad Library and
   asks you to log in -> `blocked-login`. Do not attempt credentials.
9. Download, then guard the download (section 10), then install.

Log every outcome immediately:

```powershell
.\scripts\gumroad-log-result.ps1 -Id 17292 -Outcome paid -Price 3.00 -Note 'GBP 3.00 at checkout'
.\scripts\gumroad-log-result.ps1 -Id 17293 -Outcome free-purchased
.\scripts\gumroad-log-result.ps1 -Id 17294 -Outcome blocked-login -Note 'library requires login'
```

Outcomes: `free-purchased`, `installed`, `manual`, `paid`, `blocked-login`,
`blocked-payment`, `blocked-price`, `no-link`, `error`.

**Legal/ethical**: only free (0.00) products are in scope. Never bypass a price,
never use a coupon that was not offered, never dodge a login wall.

---

## 10. Download completion guard (browser downloads)

Browser downloads are not atomic and not observable the way curl is. Distinguish
the four real states:

```powershell
.\scripts\await-download.ps1 -TimeoutSeconds 90
.\scripts\await-download.ps1 -Since 2026-11-18T17:20:00 -Expect 'Thing'
.\scripts\finish-item.ps1 -Name 'Thing' -Since 2026-11-18T17:20:00 -Expect 'Thing'
```

| State | Meaning | Exit |
| --- | --- | --- |
| `COMPLETE` | finished file with a known extension appeared | 0 |
| `COMPLETE-TMP` | partial stopped growing **and** has a valid header (ampf/PK) - finished, browser never renamed it | 0 |
| `STALLED` | partial exists and is not growing - a Save dialog is blocking | 2 |
| `NONE` | nothing appeared | 1 |

On `STALLED`, tell the operator to click **Save** (or switch the browser to
auto-download), then re-run. Never assume the file arrived because the page said
"thanks".

`finish-item.ps1` then sniffs the magic bytes, renames a stuck `.crdownload` when
it is actually complete, and installs.

---

## 11. Categorise into CATALOG.md

```powershell
.\scripts\categorize.ps1
.\scripts\categorize.ps1 -CopyTo "$HOME\Desktop"
```

Writes `<workDir>/CATALOG.md` (+ `catalog-data.json`) with:

* a **Start here** shortlist (one documented device per category),
* one table per category: `Device | What it does | Reach for it when`,
* a header stating how many rows had **no usable description** and whose text is
  inferred from the device name.

Categories: Synths, Drums & Percussion, Samplers & Granular, Sequencers &
Pattern Generators, Chords & Harmony, Modulation, Audio Effects, Push & Session
Control, Utilities, Experimental.

Honesty rule: a row with no site description says
`No usable description on the site; name suggests: <name>.` Never present a
name-derived guess as a feature list. If a category looks wrong, tune the
keyword table at the top of the script (`$rules`) - it is scored on
name (weight 3) + description (weight 1).

---

## 12. Safe batch worker pattern

When several agents or sessions work the same queue:

1. **One worker at a time.** All automation shares one browser session; parallel
   workers fight over tabs, logins and the open cart.
2. **Re-read your own results file at the start of every iteration.** It makes
   each step idempotent and lets the queue be edited between items.
3. **Write after EVERY item**, not at the end. A crash then costs one item, not
   the run. `run.ps1` does this for queue + state.
4. **Beware the PowerShell 5.1 array-nesting trap.** `@(ConvertFrom-Json ...)`
   can yield a *one-element array containing the array*, and a pipeline result of
   one element is unwrapped. Use the helpers:

   ```powershell
   $items = Read-JsonList -Path $file          # always a flat Object[]
   $items = @(Read-JsonList -Path $file)       # WRONG: nested, count becomes 1
   Write-JsonList -Path $file -Items $items    # writes [] for empty, verifies count
   ```

   `Write-JsonList` re-reads the file and throws if the element count does not
   round-trip, so a truncated write can never look like success. Never pipe a
   `Read-JsonList` call directly into `Where-Object` - assign first.
5. **Keep a heartbeat.** `monitor.ps1` reads only files: safe to poll from any
   other session while a worker runs.

---

## 13. `.amxd` internals (for dependency audits)

```
bytes 0..3    "ampf"       magic
bytes 4..7    int32        version (little endian)
bytes 8..11   "aaaa"       marker
bytes 12..    chunks:  name(4 ASCII) + int32 size + data, repeated
```

**Chunks start at offset 12.** Walk them by name/size; the next chunk begins
exactly where the previous data ended.

The `ptch` chunk holds the patch:

* gzipped if it starts `0x1f 0x8b` -> decompress, or
* plain JSON -> find the first `{` and parse from there (some writers pad a
  header before the JSON, so never assume offset 0).

```powershell
.\scripts\inspect-amxd.ps1 -Path "C:\...\Thing.amxd"
.\scripts\inspect-amxd.ps1 -Path "<UserLibrary>\Max for Live Devices" -Recurse -Json
```

Reports version, chunk table, patch encoding, sidecar references (`"file"`,
`"url"`, `js x.js`-style box text) and whether each sidecar actually exists next
to the device.

### The `dependency_cache` trap

Saved Max patches carry a `dependency_cache` array. Those entries are the
**AUTHOR'S BUILD MANIFEST**: absolute paths from *their* machine
(`C:/Users/someone/Documents/Max 8/Packages/...`). They are **not** runtime
dependencies. Their absence on your machine means nothing, and reporting them as
"missing dependencies" is the single most common false alarm when auditing a
downloaded device. Only the relative sidecar references next to the `.amxd`
matter. `inspect-amxd.ps1` prints the cache in a separate, clearly labelled
block for exactly this reason.

---

## 14. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| HTTP 403 on download, but the page loads in a browser | .NET TLS fingerprint vs Cloudflare | use `curl` (the scripts already do) |
| Every download returns a <200-byte body | HTTP 1015 rate limit, **not** missing files | do not delete anything; wait for the pacing to back off, then `run.ps1 -RetryErrors`, or restart with `-StartDelay 10` |
| Devices marked `gated` in bulk | you were throttled and the bodies were misread, or the authors moved to Gumroad | check `state.json:throttleEvents`; re-run after a cool-down; `gumroad-discover.ps1` for the rest |
| Installed device never appears in Live | wrong User Library (Documents redirected to OneDrive) | `detect-library.ps1 -List`, then `-Force` |
| Device loads but its UI/engine is missing | sidecar `.js`/`.html` left behind | install the whole zip; devices with sidecars go to `Presets/Max MIDI Effect/<Name>/` |
| Live shows indexer errors after installing a pack | C++/VS source tree in the library | it is moved to `<workDir>/quarantine/`; move any leftovers manually |
| `Expand-Archive` throws on a valid zip | bit-7 names / absolute paths / no dir entries | `install-m4l.ps1` uses `OpenRead` + per-entry extraction |
| "I want this!" does nothing on Gumroad | Inertia SPA: scripted click no-ops | go to `https://gumroad.com/checkout?product=<permalink>` |
| "Free" product totals 5.49 | pay-what-you-want default / minimum price | verify Total is 0.00; otherwise log `paid` and skip |
| Receipt bounces to the Gumroad Library login | order is tied to an account | log `blocked-login`, ask the operator |
| A `.crdownload` sits there forever | Save dialog is open | `await-download.ps1` reports `STALLED`; operator clicks Save |
| Every device reports "File not found" | same 1015 trap, misread as missing files | see above |
| Queue file suddenly has 1 item | PowerShell array nesting | use `Read-JsonList` / `Write-JsonList` |
| `& .\install-m4l.ps1` kills the calling script | `exit` in an in-process script ends the session | call siblings through `Invoke-M4LScript` (child process) |
| `.alp` will not extract | proprietary "pl-a" container | drag it into Live manually; nothing public can unpack it |

---

## 15. Command cheat sheet

```powershell
.\scripts\detect-library.ps1 -List
.\scripts\detect-library.ps1
.\scripts\list-devices.ps1 -Pages 5
.\scripts\build-queue.ps1 -Take 100
.\scripts\run.ps1 -Install -MaxRuntimeMinutes 240     # background this
.\scripts\monitor.ps1
.\scripts\inspect-amxd.ps1 -Path "<workDir>\downloads" -Recurse
.\scripts\categorize.ps1
.\scripts\gumroad-discover.ps1
.\scripts\gumroad-price-probe.ps1
.\scripts\gumroad-next.ps1
.\scripts\gumroad-log-result.ps1 -Id <id> -Outcome paid -Price 5.49
.\scripts\await-download.ps1 -TimeoutSeconds 90
.\scripts\finish-item.ps1 -Name "Thing" -Since <iso> -Expect "Thing"
```

| Script | Does |
| --- | --- |
| `_common.ps1` | config, paths, logging, magic bytes, pacing, JSON helpers, download guard |
| `detect-library.ps1` | find the User Library from Live's indexer log |
| `list-devices.ps1` | inventory maxforlive.com -> `devices.json` |
| `build-queue.ps1` | devices -> `queue.json` (skips already installed) |
| `run.ps1` | paced download worker (+ `-Install`) |
| `install-m4l.ps1` | validate + place `.amxd`/zip, quarantine build trees, reject `.alp` |
| `finish-item.ps1` | browser download -> validate -> install, one device |
| `await-download.ps1` | COMPLETE / COMPLETE-TMP / STALLED / NONE |
| `monitor.ps1` | progress, pacing, ETA, errors (file-only, safe to poll) |
| `inspect-amxd.ps1` | ampf chunk walker, sidecar refs, dependency_cache warning |
| `categorize.ps1` | categories + `CATALOG.md` with a Start-here shortlist |
| `gumroad-discover.ps1` | store front link per gated device |
| `gumroad-price-probe.ps1` | listed price + permalink + checkout URL |
| `gumroad-next.ps1` | next free candidate to check out (no purchasing) |
| `gumroad-log-result.ps1` | idempotent ledger append with count verification |
