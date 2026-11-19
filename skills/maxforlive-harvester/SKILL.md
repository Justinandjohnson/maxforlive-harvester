---
name: maxforlive-harvester
description: Find, download, verify and install Max for Live (.amxd) devices into Ableton Live by driving maxforlive.com with your own browser and shell tools. Use when bulk-adding M4L devices, refreshing a User Library after a reinstall, or harvesting free devices and packs. Also use when downloads start failing: check the HTTP status first - 429 with "error code: 1015" is rate limiting, not a missing file.
license: MIT
compatibility: Windows and macOS (Ableton Live does not run on Linux). Needs a browser or HTTP tool for pages and shell access. No scripts to install.
metadata:
  origin: community
---

# Max for Live Harvester

You do the work yourself, with the tools you already have. This file tells you what
to fetch, how to verify it, and where it goes. Nothing to install, no script to run.

**Before anything else:** read `reference/platform-paths.md` for where files go on
this machine, and check `seed/known-devices.json` so you do not redo work.

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

## 2. Find what is new

```
https://maxforlive.com/library/index.php?by=any&sortby=dev_date_added&pc=0
```

**`pc` is zero-based**: `pc=0` is the newest page, `pc=1` is the next. 9 devices per
page. Start at 0 and count up — starting at 1 silently skips the newest devices,
which is the one thing a "what's new" job must not do.

Filters: `&type=instrument`, `&type=midi`, `&type=audio`, or `&q=<search term>`.

**Each works only on its own.** Combining `q` with `type` **always returns zero
results**, so search first and filter the results yourself.

Each result is a `div.device-item` containing the date as three
`<span class="day">` elements (month, day, year), a link to
`/library/device/<id>/<slug>`, a link to `/profile/user/<author>`, and a blurb in
`div.library-device-description` — truncated to about 60 characters, so triage with it
but do not treat it as the full description.

**Remember the `type` of each device** — step 5 needs it.

### Which devices actually have a file

**Do not guess from the listing.** Some listing entries carry no form at all, and a
device with a perfectly good file can look storefront-only. Test at the device page:

- the `Device File:` row names the file (e.g. `POLYRING_11_DEMO.amxd`) → **has a file**
- that row is empty → **storefront-only**, go to step 7

The reload-safe version is simply to try the download and read the status: 200 plus
`ampf`/`PK` means it has a file; a short `File not found` body means it does not.

Do not open a storefront-only device looking for a download button. There isn't one.

### Diff against the seed

`seed/known-devices.json` holds 877 devices, each with an `id` and an `outcome`.

Skip an id already there **only on a diff run**. The seed records one earlier harvest,
**not** the user's library. If their library was wiped, or they asked for everything,
harvest the free ids in the seed too.

Filter on `id`, never on name — names get edited, ids do not.

### Outcome tokens

| Token | Meaning |
| --- | --- |
| `downloaded` | fetched, verified, installed |
| `gated` | no file hosted on the site (never uploaded, or removed) |
| `paid` | behind a real price; not bought |
| `not-for-sale` | listing withdrawn |
| `blocked` | needed an address, an email the user wouldn't give, or similar |
| `blocked-login` | order completed, download is behind an account login |
| `available` | hosts a file, but you did not download it this run (e.g. the user only wanted the newest one) |

## 3. Download

Device page: `https://maxforlive.com/library/device/<id>/<slug>` (the slug is optional).

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
  exits 0 — you get a "successful" download that is actually an error message.
- **One file per device** (`<id>.bin`). Never reuse a filename or you will install the
  previous device by mistake.
- No cookies or referer are required.
- The device page's `Device File:` row names the file before you fetch it — a better
  signal than guessing from magic bytes afterwards.

### The rate-limit trap — read the status code, not the body

Burst `/download.php` and it returns **HTTP 429**. Two possible bodies: a 17-byte
`error code: 1015`, or a ~8 KB Cloudflare "Access denied" page.

**Only `/download.php` is throttled.** Listing and device pages keep returning 200
while downloads are blocked, so you can still browse. Recovery has been observed
taking over 70 seconds.

Pace at **one download every 2-3 seconds**. If you get a 429, stop, wait a minute,
then probe with a device you know exists (a seed id whose `outcome` is `downloaded`).

**A 429 is not the same as `File not found`.** `File not found` is a real, separate
response meaning that device has no file hosted here — never uploaded, or removed.
Check the `Website:` row before assuming anything. Either way it is not your error:
record `gated` and move on.

## 4. Verify — and pick the right extension

| First bytes | It is | Rename to |
| --- | --- | --- |
| `ampf` | a Max device | `.amxd` |
| `PK` | a zip | `.zip` |
| `pl-a` | an Ableton Pack | `.alp` |
| `<!do`, `<?xm` | an HTML/XML error page | not a file |
| under ~200 bytes of text | an error string | not a file |

```bash
head -c 4 downloads/<id>.bin      # macOS -> prints ampf / PK / pl-a
```

```powershell
# Windows, PowerShell 5.1 and 7. Resolve-Path matters: .NET uses the process
# working directory, not the shell's, so a bare relative name fails after a cd.
$p = (Resolve-Path "downloads\<id>.bin").Path
[System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($p)[0..3])
```

**Rename to match.** Live only indexes files ending in `.amxd` — a correctly
downloaded device left as `<id>.bin` installs invisibly. This is the easiest way to
"finish" a harvest that does nothing.

## 5. Install

Exact paths per OS are in `reference/platform-paths.md`. Create the destination folder
first — `mkdir -p` / `New-Item -ItemType Directory -Force`.

**Keep a device's support files in one folder with it.** If the `.amxd` has a sibling
`.js`, `.html`, `.json`, `.woff2` or similar, keep them together:

```
<UserLibrary>/Max for Live Devices/<Collection>/<Name>/
```

Support files must travel with the device or it will not load. This beats the plain
placement below.

Otherwise, for a device with no siblings:

- **Instruments** → `Presets/Instruments/<Name>/`
- **Audio effects** → `Presets/Audio Effects/<Name>/`
- **MIDI effects** → `Presets/Max MIDI Effect/<Name>/`
- **Anything else** → `<UserLibrary>/Max for Live Devices/<Collection>/`

`Presets/` on a real install contains only `Audio Effects`, `Instruments`,
`Max MIDI Effect` and `MIDI Effects` — there is no `Max Audio Effect` or
`Max Instrument`, so do not invent those.

Other cases:

- **`.zip`** → extract into its own folder under the collection and confirm an `.amxd`
  came out. If none did, delete the extracted folder, record `gated` — some store zips
  are VST3-only.
- **Strip build trees.** If you see `Source/`, `src/`, `bin/`, `.sln`, `.vcxproj`,
  keep only the device, support files, presets and docs. Stray source trees make Live's
  indexer throw errors.
- **`.alp`** → an Ableton Pack: gzip, sometimes behind a 12-byte `pl-a` header, and
  some are bare gzip with no header at all. It **can** be decompressed, but that yields
  a Live Set (`.als`) plus samples — not installable devices. Leave it in Downloads and
  tell the user to drag it onto Live or double-click it. Do not hand-install its
  contents.

**Finding the User Library is the step people get wrong.** `~/Documents` is often
redirected into OneDrive or iCloud; writing to `Documents/Ableton/User Library` while
Live indexes `OneDrive/Documents/...` produces installs that succeed and never appear.
Read Live's indexer log and use the path it reports.

## 6. Make Live see it

Usually nothing is needed: Live watches the User Library via OS file events and picks
new devices up within seconds. Confirm via the indexer log rather than assuming.

If they do not appear, ask the user to right-click **User Library → Refresh Browser**.
Do not restart Live for them.

## 7. Devices whose files moved to a store front

Roughly half the catalogue — and most of the newest listings — no longer hosts files
on maxforlive.com. Authors move to Gumroad, Sellfy, Ko-fi, Payhip, Boosty, Lemon
Squeezy, or their own site.

**The link is in the `Website:` row of the Details table**, not in the description.
Handle any store the same way.

**Free only. This is the whole point.**

1. Open the page and read the price. Not 0 → record `paid` with the price, stop.
2. Open the checkout. On Gumroad that is
   `https://gumroad.com/checkout?product=<permalink>` — read the permalink from the
   page, because clicking "I want this!" often does nothing.
3. **Confirm the cart total is 0.00** before submitting. If not, abort.
4. Enter the user's email, submit, download, verify as in step 4.

If the receipt bounces to the Gumroad Library asking for a login, record
`blocked-login`. If a checkout demands a postal address, ask the user; do not invent
one.

**No Gumroad MCP can help.** Every one is seller-side, keyed to the user's own store,
and Gumroad states it does not take payments in chat. Purchasing is browser-only.

## 8. Report honestly, and update the seed

Append one record per device to `seed/known-devices.json`, keeping the existing keys
(`id`, `name`, `author`, `year`, `link`, `outcome`, `seen`, `note`). Without this the
diff never improves and the next run redoes the same work.

Then report six numbers: downloaded, gated, paid (with price range), not-for-sale,
blocked, blocked-login. Do not describe a paywall as a failure, and do not imply you
fetched something you did not. If you were rate limited, say so — it changes what the
numbers mean.
