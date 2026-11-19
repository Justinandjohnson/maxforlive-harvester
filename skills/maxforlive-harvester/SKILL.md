---
name: maxforlive-harvester
description: Find, download, verify and install Max for Live (.amxd) devices into Ableton Live by driving maxforlive.com with your own browser and shell tools. Use when bulk-adding M4L devices, refreshing a User Library after a reinstall, or harvesting free devices and packs. Also use when a previous attempt returned "File not found" for every device - that is usually HTTP 1015 rate limiting, not missing files.
license: MIT
compatibility: Any OS with a shell (Windows, macOS, Linux). Needs a browser or HTTP tool for pages, and Ableton Live with Max for Live. No scripts to install.
metadata:
  origin: community
---

# Max for Live Harvester

You do the work yourself, with the tools you already have. This file tells you what
to fetch, how to verify it, and where it goes. There is nothing to install and no
script to run.

**Before anything else:** read `reference/platform-paths.md` for where files go on
this machine, and check `seed/known-devices.json` so you do not redo work that has
already been done.

---

## 1. Hard rules

These are not style preferences. Breaking them wastes the user's time or money.

- **Never spend money.** On Gumroad, only submit a checkout when the **cart total**
  is 0.00. Check the cart, not the listing: a "$0+" pay-what-you-want product has
  been observed totalling $5.49 at checkout. Record anything above zero as `paid`
  and move on.
- **Never enter card or payment details.** Email only, for free items.
- **Ask the user for their email.** Never invent one, never reuse one from earlier
  in the conversation or from any file.
- **Never take window focus.** Do not click into the user's desktop apps. A window
  stealing focus interrupts them mid-game. Browser automation inside your own
  panel or headless context is fine; hijacking their foreground window is not.
- **Never replace `libusb-1.0.dll` or a Live control-surface script.** That is how
  people break a working Push. It is out of scope here.
- **Never install a file you have not verified** (see step 4). A 14-byte "file" is
  an error message, not a device.

## 2. Find what is new

List devices from the catalogue, newest first:

```
https://maxforlive.com/library/index.php?by=any&sortby=dev_date_added&pc=<page>
```

Useful filters: `&type=instrument`, `&type=midi`, `&type=audio`, `&q=<search term>`.

Each result is a `div.device-item` containing:

- the date, as three `<span class="day">` elements (month, day, year)
- `a` → `/library/device/<id>/<slug>`
- `a` → `/profile/user/<author>`
- `div.library-device-description` → the blurb

**Diff against the seed first.** Open `seed/known-devices.json`. It holds 877
devices, each with an `id` and an `outcome`. Skip any id already there. Filter on
`id`, never on name — device names get edited, ids do not. If the user only wants
new things, this turns an hours-long job into a two-minute one.

## 3. Download

The device page is `https://maxforlive.com/library/device/<id>/<slug>`.

**Preferred:** open that page in your browser and click the **"Download Device"**
button. It POSTs to `/download.php` and returns the file.

**If you have no browser**, the equivalent request is:

```bash
curl -sS -L \
  -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
  -e "https://maxforlive.com/library/device/<id>/" \
  --data "id=<id>&submit=Download+Device" \
  -o out.bin \
  "https://maxforlive.com/download.php"
```

Two things will bite you:

- **Cloudflare 403s some HTTP clients.** If a request 403s, try a browser, or a
  different HTTP client. Do not retry the same broken client in a loop.
- **The rate limiter looks like missing files.** Burst more than roughly twenty
  requests and you get HTTP 429 with a body reading `error code: 1015`. From then
  on *everything* looks like `File not found`, which is indistinguishable from a
  device whose author deleted the file. If you see many `File not found` in a row,
  stop, wait a minute, and retry a device you know exists to test. Pace yourself:
  roughly one request every 2-3 seconds, slower if you get throttled.

## 4. Verify before you trust anything

| Kind | Test | Means |
| --- | --- | --- |
| `.amxd` | first 4 bytes are `ampf` | a real Max device |
| `.zip` | first 2 bytes are `PK` | a real archive |
| anything else | under ~200 bytes | an error string, not a file |

```bash
head -c 4 out.bin        # macOS / Linux
```

```powershell
(Get-Content out.bin -AsByteStream -TotalCount 4)   # Windows PowerShell 7
[System.IO.File]::ReadAllBytes("out.bin")[0..3]     # Windows PowerShell 5.1
```

A short body reading `File not found` means the author removed it from the site.
That is not your error and it is not fixable. Record it and move on.

## 5. Install

Full paths for each platform are in `reference/platform-paths.md`. The rules:

- **Plain `.amxd`** → `<User Library>/Max for Live Devices/<Your Collection>/`
- **`.amxd` with sibling `.js` / `.html` / `.json`** → `<User Library>/Presets/Max MIDI Effect/<Name>/`
  The support files must travel with the device or it will not load.
- **`.zip`** → extract into its own folder under the collection, then confirm there
  is an `.amxd` inside. Many M4L zips include a build tree: if you see `Source/`,
  `.sln`, `src/` or `bin/`, keep only the device, support files, docs and presets.
  Stray source trees make Live's indexer throw errors.
- **`.alp`** → this is an Ableton Pack in a proprietary `pl-a` container. It
  **cannot** be unpacked. Leave it in Downloads and tell the user to drag it onto
  Live. Do not try to extract it.

**Finding the User Library is the step people get wrong.**
`~/Documents` is frequently redirected into OneDrive or iCloud. Writing into
`Documents/Ableton/User Library` while Live indexes `OneDrive/Documents/...`
produces installs that succeed and never appear. Read Live's own indexer log and
take the path it reports — `reference/platform-paths.md` gives the location and the
exact line to look for. If a second library exists, tell the user rather than
guessing which one is live.

## 6. Make Live see it

Usually nothing is needed: Live watches the User Library via OS file events and
picks new devices up within seconds. Confirm rather than assume — the indexer log
will show a scan of the folder you wrote to.

If the devices do not appear, tell the user to right-click **User Library → Refresh
Browser**. Do not restart Live for them.

## 7. Devices whose files moved to a store front

Roughly a third of the catalogue no longer hosts files on maxforlive.com; the author
moved to Gumroad, Ko-fi, Payhip or Lemon Squeezy. You can find the link on the
device page — look for a Gumroad or store-front URL in the description.

**Free only. This is the whole point.**

1. Open the product page, read the price.
2. If it is not 0, record `paid` with the price and stop. Do not buy it.
3. Open the checkout: `https://gumroad.com/checkout?product=<permalink>`
   (read the permalink from the product page; clicking "I want this!" often does
   nothing on these pages).
4. **Confirm the cart total is 0.00** before submitting. If it is not, abort.
5. Enter the user's email, submit, download, verify as in step 4.

If the order completes but the receipt bounces to the Gumroad Library asking for a
login, record `blocked-login` and tell the user to grab it from their library.
If a checkout demands a postal address, ask the user; do not invent one.

Note: **no Gumroad MCP can help here.** Every existing one is seller-side, keyed to
the user's own store. Purchasing is browser-only.

## 8. Report honestly

Tell the user four numbers: downloaded, paid (with the price range), not-for-sale,
blocked. Do not describe a paywall as a failure, and do not imply you fetched
something you did not. If you were rate limited, say so — it changes what the
numbers mean.
