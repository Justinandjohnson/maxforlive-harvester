---
name: maxforlive-harvester
description: Find, download, verify and install Max for Live (.amxd) devices into Ableton Live by driving maxforlive.com with your own browser and shell tools. Use when bulk-adding M4L devices, refreshing a User Library after a reinstall, or harvesting free devices and packs. Also use when a previous attempt returned "File not found" for every device - that is usually HTTP 1015 rate limiting, not missing files.
license: MIT
compatibility: Windows and macOS (Ableton Live does not run on Linux). Needs a browser or HTTP tool for pages and shell access. No scripts to install.
metadata:
  origin: community
---

# Max for Live Harvester

You do the work yourself, with the tools you already have. This file tells you what
to fetch, how to verify it, and where it goes. There is nothing to install and no
script to run.

**Before anything else:** read `reference/platform-paths.md` for where files go on
this machine, and check `seed/known-devices.json` so you do not redo work.

---

## 1. Hard rules

- **Never spend money.** On Gumroad, only submit a checkout when the **cart total** is
  0.00. Check the cart, not the listing — a "$0+" pay-what-you-want product has been
  seen totalling $5.49 at checkout. Record anything above zero as `paid` and move on.
- **Never enter card or payment details.** Email only, for free items.
- **Ask the user for their email.** Never invent one, never reuse one from earlier in
  the conversation or from a file. If they decline to give one, record `blocked` and
  move on — do not find a workaround.
- **Never take window focus.** Do not click into the user's desktop apps; a window
  stealing focus interrupts them mid-game. Browser work inside your own panel or a
  headless context is fine.
- **Never replace `libusb-1.0.dll` or a Live control-surface script.** That is how
  people break a working Push. Out of scope.
- **Never install a file you have not verified** (step 4). A 14-byte "file" is an
  error message, not a device.

## 2. Find what is new

List the catalogue, newest first:

```
https://maxforlive.com/library/index.php?by=any&sortby=dev_date_added&pc=<page>
```

Filters that work: `&type=instrument`, `&type=midi`, `&type=audio`, `&q=<term>`.
**Remember the `type` of each device** — step 5 needs it for placement.

Each result is a `div.device-item` containing the date as three
`<span class="day">` elements (month, day, year), a link to
`/library/device/<id>/<slug>`, a link to `/profile/user/<author>`, and the blurb in
`div.library-device-description`.

### Diff against the seed

`seed/known-devices.json` holds 877 devices, each with an `id` and an `outcome`.

Skip an id already there **only on a diff run**, when the user wants what's new.
The seed records one earlier harvest, **not** the user's library. If their library
was wiped, or they asked for everything, harvest the free ids in the seed too.

Filter on `id`, never on name — names get edited, ids do not.

### Outcome tokens

Use exactly these, so results stay comparable:

| Token | Meaning |
| --- | --- |
| `downloaded` | fetched, verified and installed |
| `gated` | the site has no file for it — including "File not found" responses |
| `paid` | behind a real price; not bought |
| `not-for-sale` | listing withdrawn |
| `blocked` | needed an address, an email the user wouldn't give, or something you cannot supply |
| `blocked-login` | order completed but the download is behind an account login |

## 3. Download

Device page: `https://maxforlive.com/library/device/<id>/<slug>`

**Preferred:** open it in your browser and click **"Download Device"**. It POSTs to
`/download.php` and returns the file.

**With no browser**, the equivalent:

```bash
curl -sS -L \
  -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -e "https://maxforlive.com/library/device/<id>/" \
  --data "id=<id>&submit=Download+Device" \
  -o "downloads/<id>.bin" \
  -w '\nHTTP %{http_code}\n' \
  "https://maxforlive.com/download.php"
```

- **Write one file per device** (`<id>.bin`). Never reuse one filename — you will
  install the previous device by mistake.
- **Read the HTTP code.** Without `-w` a 403 and a 200 look identical.
- Cloudflare 403s some HTTP clients. If you get one, try a browser or a different
  client; do not retry the same one in a loop.

### The rate-limit trap

Burst more than roughly twenty requests and you get HTTP 429 with a body reading
`error code: 1015`. From then on **every** request returns `File not found`, which is
indistinguishable from a device whose author deleted the file.

Pace at 2-3 seconds per request. If several `File not found` responses arrive in a
row, stop and probe: either re-fetch an id whose seed `outcome` is `downloaded`, or
fetch `https://maxforlive.com/library/index.php` and check you get HTML rather than
`error code: 1015`. Only after that probe passes can you trust a `gated` result.

## 4. Verify — and pick the right extension

| First bytes | It is | Rename to |
| --- | --- | --- |
| `ampf` | a Max device | `.amxd` |
| `PK` | a zip | `.zip` |
| `pl-a` | an Ableton Pack | `.alp` |
| under ~200 bytes of text | an error message | not a file |

```bash
head -c 4 downloads/<id>.bin                       # macOS -> prints ampf / PK / pl-a
```

```powershell
# Windows, PowerShell 5.1 and 7. Resolve-Path matters: .NET uses the process
# working directory, not the shell's, so a bare relative name fails after a cd.
$p = (Resolve-Path "downloads\<id>.bin").Path
[System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($p)[0..3])
```

**Rename the file to match.** Live only indexes files ending in `.amxd` — a correctly
downloaded device left as `<id>.bin` installs invisibly. This is the easiest way to
"finish" a harvest that does nothing.

A short body reading `File not found` means the author removed it. That is not your
error. Record `gated` and move on.

## 5. Install

Exact paths per OS are in `reference/platform-paths.md`. Create the destination
folder before copying — `New-Item -ItemType Directory -Force` / `mkdir -p`.

**A device with support files wins over the zip rule.** If an extracted device has a
sibling `.js`, `.html` or `.json` beside the `.amxd`, the whole folder goes into the
matching Presets tree, not into the collection folder:

| Device type (from step 2) | Destination |
| --- | --- |
| instrument | `Presets/Instruments/Max Instrument/<Name>/` |
| audio effect | `Presets/Audio Effects/Max Audio Effect/<Name>/` |
| MIDI effect | `Presets/MIDI Effects/Max MIDI Effect/<Name>/` |

Otherwise:

- **Plain `.amxd`, no siblings** → `<UserLibrary>/Max for Live Devices/<Collection>/`
- **`.zip`** → extract into its own folder under the collection and confirm an
  `.amxd` came out. Keeping docs and presets is fine.
  **If no `.amxd` is inside, delete the extracted folder, record `gated`, and move
  on** — some store zips are VST3-only.
- **Strip build trees.** If you see `Source/`, `src/`, `bin/`, `.sln` or `.vcxproj`,
  keep only the device, support files, presets and docs. Stray source trees make
  Live's indexer throw errors.
- **`.alp`** — a proprietary `pl-a` container. It **cannot** be unpacked. Leave it in
  Downloads and tell the user to drag it onto Live.

**Finding the User Library is the step people get wrong.** `~/Documents` is often
redirected into OneDrive or iCloud; writing to `Documents/Ableton/User Library` while
Live indexes `OneDrive/Documents/...` produces installs that succeed and never
appear. Read Live's own indexer log and use the path it reports —
`reference/platform-paths.md` has the location and the exact line.

## 6. Make Live see it

Usually nothing is needed: Live watches the User Library via OS file events and picks
new devices up within seconds. Confirm via the indexer log rather than assuming.

If they do not appear, ask the user to right-click **User Library → Refresh
Browser**. Do not restart Live for them.

## 7. Devices whose files moved to a store front

Some devices no longer host a file on maxforlive.com. Where the author moved to a
store front the device page usually links to it — look for a Gumroad, Ko-fi, Payhip
or Lemon Squeezy URL in the description. If there is no link, the file is simply
gone: record `gated` and move on rather than guessing at a store.

**Free only. This is the whole point.**

1. Open the product page and read the price. Not 0 → record `paid` with the price, stop.
2. Open `https://gumroad.com/checkout?product=<permalink>` (read the permalink from
   the page; clicking "I want this!" often does nothing on these pages).
3. **Confirm the cart total is 0.00** before submitting. If not, abort.
4. Enter the user's email, submit, download, then verify as in step 4.

If the receipt bounces to the Gumroad Library asking for a login, record
`blocked-login`. If a checkout demands a postal address, ask the user; do not invent
one.

Note: **no Gumroad MCP can help here.** Every existing one is seller-side, keyed to
the user's own store. Purchasing is browser-only.

## 8. Report honestly, and update the seed

Append one record per device to `seed/known-devices.json`, keeping the existing keys
(`id`, `name`, `author`, `year`, `link`, `outcome`, `seen`, `note`). Without this the
diff never improves and the next run redoes the same work.

Then tell the user six numbers: downloaded, gated, paid (with the price range),
not-for-sale, blocked, blocked-login. Do not describe a paywall as a failure, and do
not imply you fetched something you did not. If you were rate limited, say so — it
changes what the numbers mean.
