# Max for Live Harvester

An **agent skill** that fills an Ableton Live User Library with free Max for Live
devices. Your agent does the work itself — there are no scripts to run.

- The skill is **[skills/maxforlive-harvester/SKILL.md](skills/maxforlive-harvester/SKILL.md)**. That file is the whole thing.
- `reference/platform-paths.md` in the same folder gives the on-disk paths per OS.
- `seed/known-devices.json` lists 877 devices already indexed so you skip them.
- If your tool reads `SKILL.md` skills (Claude Code, Codex, Cursor, OpenCode), that file is the entry point. If it reads `AGENTS.md`, the rules below are what matter.

## Hard rules — do not skip these

- **Spend no money.** Gumroad checkouts only when the **cart total** is 0.00. Check
  the cart, not the listing — a "$0+" product has been seen totalling $5.49.
- **Never enter card or payment details.** Email only.
- **Ask the user for their email.** Never invent an address, never reuse one.
- **Never take window focus.** A window stealing focus interrupts the user.
- **Never replace `libusb-1.0.dll` or a control-surface script.** Out of scope.
- **Never install an unverified file.** `.amxd` must start with `ampf`; `.zip` with `PK`.

## The rate-limit trap

Burst `/download.php` and it returns **HTTP 429** — either a 17-byte `error code: 1015`
or a ~8 KB Cloudflare "Access denied" page. **Only `download.php` is throttled**;
listing and device pages keep returning 200 while downloads are blocked. Recovery has
been observed taking over 70 seconds.

Pace at **one download every 2-3 seconds**, and read the status code.

**A 429 is not "File not found".** `File not found` is a separate, real response
meaning that device has no file hosted here. Never conclude files are missing from a
429.

## Finding the User Library

Never assume `~/Documents/Ableton/User Library` — Documents is commonly redirected to
OneDrive or iCloud, and writing there produces installs that succeed and never
appear. Read Live's own indexer log and use the path it reports. Locations for each
OS are in `reference/platform-paths.md`.

## Verify before claiming success

- `.amxd` starts with `ampf`; `.zip` starts with `PK`; anything under ~200 bytes is an
  error message, not a file.
- Confirm the file landed on disk before moving on.
- `.alp` packs cannot be unpacked — the user must drag them into Live.
