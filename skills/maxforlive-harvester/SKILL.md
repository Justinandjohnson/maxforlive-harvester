---
name: maxforlive-harvester
description: Find, download, verify and install Max for Live (.amxd) devices into Ableton Live by driving maxforlive.com with your own browser and shell tools. Use when bulk-adding M4L devices, refreshing a User Library after a reinstall, or harvesting free devices and packs. Also use when downloads start failing: check the HTTP status first - 429 with "error code: 1015" is rate limiting, not a missing file.
license: MIT
compatibility: Windows and macOS (Ableton Live does not run on Linux). Needs a browser or HTTP tool for pages and shell access. No scripts to install.
metadata:
  origin: community
---

# Max for Live Harvester

You do the work yourself, with the tools you already have. This one file is the whole
skill: what to fetch, how to verify it, and where it goes. Nothing to install, no
script to run, no other files needed.

**Optional speed-up:** `seed/known-devices.json` in this folder — or fetched from
`https://raw.githubusercontent.com/Justinandjohnson/maxforlive-harvester/master/skills/maxforlive-harvester/seed/known-devices.json`
— lists 877 devices already harvested with their outcome. If you have it, skip any id
already present. If you do not, the skill still works; it just redoes more work.

---

## 1. Hard rules

- **Never spend money.** On Gumroad, only submit a checkout when the **cart total** is
  0.00. Check the cart, not the listing — a "$0+" pay-what-you-want product has been
  seen totalling $5.49 at checkout. Record anything above zero as `paid` and move on.
- **Never enter card or payment details.** Email only, for free items.
- **Ask the user for their email.** Never invent one, never reuse one from earlier in
  the conversation or from a file. If they decline, record `blocked` and move on.
- **Never take window focus.** Browser work inside your own panel or a headless
  context is fine; hijacking their foreground window is not.
- **Never replace `libusb-1.0.dll` or a Live control-surface script.** Out of scope.
- **Never install a file you have not verified** (step 4).

## 2. Find the User Library first

**Do not assume `~/Documents/Ableton/User Library`.** Documents is often redirected to
OneDrive or iCloud, and writing there produces installs that succeed and never appear in
Live. Read Live's own indexer log and use the path it reports.

| Platform | Indexer log | Default if unreadable |
| --- | --- | --- |
| Windows | `%APPDATA%\Ableton\Live <VER>\Preferences\Indexer.txt` | `%USERPROFILE%\Documents\Ableton\User Library` |
| macOS | `~/Library/Preferences/Ableton/Live <VER>/Indexer.txt` | `~/Music/Ableton/User Library` |

Note the asymmetry: Windows nests `Preferences\`, macOS does not.

```bash
grep 'UserLibrary:' ~/Library/Preferences/Ableton/Live*/Indexer.txt     # macOS
```

```powershell
Get-ChildItem "$env:APPDATA\Ableton\Live*\Preferences\Indexer.txt" |
  Sort-Object LastWriteTime | Select-Object -Last 1 |
  Get-Content | Select-String 'Configure: UserLibrary:' | Select-Object -Last 1
```

The line comes in two forms — take the **last** match from the **newest** version,
strip quotes and any trailing `[User Library]`:

```
Configure: UserLibrary: 'C:\Users\...\User Library' [User Library]   # Live 12
Configure: UserLibrary: C:\Users\...\User Library                    # Live 11
```

A `Live*` glob matches every installed version including stale betas — the first hit
can be a library you no longer use. If the log lists more than one library, ask the
user which is live.

## 3. Find what is new

```
https://maxforlive.com/library/index.php?by=any&sortby=dev_date_added&pc=0
```

**`pc` is zero-based**: `pc=0` is the newest page, `pc=1` the next, 9 devices per page.
Start at 0 — starting at 1 silently skips the newest devices.

Filters: `&type=instrument`, `&type=midi`, `&type=audio`, or `&q=<search term>`.
**Each works only on its own.** Combining `q` with `type` always returns zero results,
so search first and filter the results yourself.

Each result is a `div.device-item` containing the date as three `<span class="day">`
elements (month, day, year), a link to `/library/device/<id>/<slug>`, a link to
`/profile/user/<author>`, and a blurb in `div.library-device-description` — truncated
to about 60 characters, so triage with it but do not treat it as the full description.

**Remember the `type` of each device** — step 6 needs it.

### Does it actually host a file?

Do not guess from the listing; some entries carry no form at all and a device with a
good file can look storefront-only. Check the **device page**: a filled `Device File:`
row means it has a file; an empty one means storefront-only (step 7).

### Diff against the seed (if you have it)

Skip an id already in `known-devices.json` **only on a diff run**. The seed records one
earlier harvest, not the user's library. If their library was wiped, or they asked for
everything, harvest the free ids in the seed too. Filter on `id`, never on name — names
get edited, ids do not.

### Outcome tokens

| Token | Meaning |
| --- | --- |
| `downloaded` | fetched, verified, installed |
| `gated` | no file hosted on the site (never uploaded, or removed) |
| `available` | hosts a file, but not downloaded this run |
| `paid` | behind a real price; not bought |
| `not-for-sale` | listing withdrawn |
| `blocked` | needed an address, an email the user wouldn't give, or similar |
| `blocked-login` | order completed, download is behind an account login |

## 4. Download

Device page: `https://maxforlive.com/library/device/<id>/<slug>` (slug optional).

**Preferred:** open it and submit the **"Download Device"** form. It posts to
`/download.php` and returns the file.

**Without a browser:**

```bash
curl -sS -f -L \
  -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  --data "id=<id>" \
  -o "downloads/<id>.bin" \
  "https://maxforlive.com/download.php"
```

- **`-f` is not optional.** Without it a 429 is written into the file and curl still
  exits 0 — a "successful" download that is actually an error message.
- **One file per device** (`<id>.bin`). Reusing a filename installs the previous
  device by mistake.
- No cookies or referer required.
- The `Device File:` row names the file before you fetch it.

### The rate-limit trap — read the status, not the body

Burst `/download.php` and it returns **HTTP 429**: either a 17-byte `error code: 1015`
or a ~8 KB Cloudflare page. **Only `/download.php` is throttled** — listing and device
pages keep returning 200, so you can still browse. Recovery has been observed taking
over 70 seconds.

Pace at **one download every 2-3 seconds**. On a 429, stop, wait a minute, then probe a
device you know exists.

**A 429 is not `File not found`.** That is a separate, real response: this device has
no file hosted here. Check the `Website:` row before assuming anything. Either way it
is not your error — record `gated` and move on.

## 5. Verify — and pick the right extension

| First bytes | It is | Rename to |
| --- | --- | --- |
| `ampf` | a Max device | `.amxd` |
| `PK` | a zip | `.zip` |
| `pl-a` | an Ableton Pack | `.alp` |
| `<!do`, `<?xm` | an HTML/XML error page | not a file |
| under ~200 bytes of text | an error string | not a file |

```bash
head -c 4 downloads/<id>.bin                    # macOS -> ampf / PK / pl-a
```

```powershell
# Windows, PowerShell 5.1 and 7. Resolve-Path matters: .NET resolves against the
# process working directory, not the shell's, so a bare relative name fails after a cd.
$p = (Resolve-Path "downloads\<id>.bin").Path
[System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($p)[0..3])
```

Make sure it prints **text**, not numbers. `97,109,112,102` *is* `ampf` — raw bytes mean
you have not checked anything yet.

**Rename to match.** Live only indexes `.amxd`; a correct download left as `<id>.bin`
installs invisibly. That is the easiest way to "finish" a harvest that does nothing.

## 6. Install

Create the destination folder first — `mkdir -p` / `New-Item -ItemType Directory -Force`.

**Support files win.** If the `.amxd` has a sibling `.js`, `.html`, `.json` or
`.woff2`, keep the whole folder together:

```
<UserLibrary>/Max for Live Devices/<Collection>/<Name>/
```

They must travel with the device or it will not load.

Otherwise, for a device with no siblings:

| Device type | Destination |
| --- | --- |
| instrument | `Presets/Instruments/<Name>/` |
| audio effect | `Presets/Audio Effects/<Name>/` |
| MIDI effect | `Presets/Max MIDI Effect/<Name>/` |
| anything else | `Max for Live Devices/<Collection>/` |

A real `Presets/` contains only `Audio Effects`, `Instruments`, `Max MIDI Effect`,
`MIDI Effects`. Do **not** invent `Max Audio Effect` or `Max Instrument` — they do not
exist on a normal install.

Other cases:

- **`.zip`** → extract into its own folder under the collection; confirm an `.amxd`
  came out. If none did, delete it and record `gated` — some store zips are VST3-only.
- **Strip build trees.** `Source/`, `src/`, `bin/`, `.sln`, `.vcxproj` → keep only the
  device, support files, presets and docs. Stray source trees make Live's indexer throw.
- **`.alp`** → gzip, sometimes behind a 12-byte `pl-a` header, sometimes bare gzip. It
  **can** be decompressed, but that yields a Live Set (`.als`) plus samples, not
  installable devices. Leave it in Downloads; the user drags it onto Live.

```bash
# extract, when Expand-Archive throws (it often does)
unzip -o archive.zip -d target/ && rm -rf target/__MACOSX
```

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$a = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path "archive.zip").Path)
foreach ($e in $a.Entries) {
  if ([string]::IsNullOrEmpty($e.Name) -or $e.FullName -like '*__MACOSX*') { continue }
  $out = Join-Path "target" $e.FullName
  New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
  [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
}
$a.Dispose()
```

## 7. Make Live see it

Usually nothing is needed — Live watches the User Library via OS file events and picks
new devices up within seconds. Confirm via the indexer log rather than assuming.

If they do not appear, ask the user to right-click **User Library → Refresh Browser**.
Do not restart Live for them.

## 8. Devices whose files moved to a store front

Roughly half the catalogue, and most of the newest listings, no longer hosts files
here. Authors move to Gumroad, Sellfy, Ko-fi, Payhip, Boosty, Lemon Squeezy, or their
own site. **The link is in the `Website:` row of the device page**, not the description.

**Free only. This is the whole point.**

1. Open the page, read the price. Not 0 → record `paid` with the price, stop.
2. Open the checkout. On Gumroad: `https://gumroad.com/checkout?product=<permalink>` —
   read the permalink from the page, because clicking "I want this!" often does nothing.
3. **Confirm the cart total is 0.00** before submitting. If not, abort.
4. Enter the user's email, submit, download, verify as in step 5.

Receipt bounces to a Gumroad Library asking for login → record `blocked-login`.
Checkout demands a postal address → ask the user; do not invent one.

**No Gumroad MCP can help.** Every one is seller-side, keyed to the user's own store,
and Gumroad states it does not take payments in chat. Purchasing is browser-only.

## 9. Report honestly, and update the seed

If you have `known-devices.json`, append one record per device keeping its keys
(`id`, `name`, `author`, `year`, `link`, `outcome`, `seen`, `note`). Without this the
diff never improves.

Then report six numbers: downloaded, gated, paid (with price range), not-for-sale,
blocked, blocked-login. Do not describe a paywall as a failure, and do not imply you
fetched something you did not. If you were rate limited, say so — it changes what the
numbers mean.
