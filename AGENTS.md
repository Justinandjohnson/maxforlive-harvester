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

Burst more than roughly twenty requests and maxforlive.com returns HTTP 429 with a
body reading `error code: 1015`. After that **every** request looks like
`File not found`, which is indistinguishable from a device whose author deleted the
file. Pace at 2-3 seconds per request. If you see many "File not found" in a row,
stop and retest with a device you know exists before concluding anything.

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
