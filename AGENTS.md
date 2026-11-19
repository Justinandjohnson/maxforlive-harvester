# Max for Live Harvester

An **agent skill** that fills an Ableton Live User Library with free Max for Live devices.

- The instructions are in **[skills/maxforlive-harvester/SKILL.md](skills/maxforlive-harvester/SKILL.md)** — read it first, it is the whole playbook.
- If your tool reads `SKILL.md` skills (Claude Code, Codex, Cursor, OpenCode), that file is the entry point and this one is mostly redundant.
- If your tool reads `AGENTS.md`, the rules below are the part that matters before you touch anything.

Everything lives under `skills/maxforlive-harvester/` — `scripts/`, `seed/`, `config.example.json`.

## Before you run anything

```powershell
Copy-Item skills/maxforlive-harvester/config.example.json skills/maxforlive-harvester/config.json
pwsh skills/maxforlive-harvester/scripts/detect-library.ps1
```

`detect-library.ps1` finds the real User Library from Live's own indexer log. **Never**
assume `~/Documents/Ableton/User Library` — Documents is commonly redirected to
OneDrive, and writing there produces installs that succeed and never appear in Live.

Then run `diff-known.ps1` before any full harvest. It reports only devices missing
from `seed/known-devices.json` (877 already indexed with outcomes). A full sweep is
hours; a diff is minutes.

## Hard rules — do not skip these

- **Spend no money.** Gumroad checkouts only when the cart total is 0.00. Verify the
  cart total, not the listing — a "$0+" pay-what-you-want product can total more.
- **Never enter card or payment details.** Email only.
- **Ask the user for their email.** `config.json:buyerEmail` ships empty on purpose.
  Never invent an address; never reuse one from a previous session.
- **Never take window focus.** Use background jobs for long runs. A window stealing
  focus interrupts the user.
- **Keep the pacing defaults.** Raising them trips the site's rate limiter (HTTP
  1015), whose response is indistinguishable from "File not found" — you will
  silently harvest nothing and conclude the site is empty.

## Verify before claiming success

- Every `.amxd` must start with the ASCII magic `ampf`; every `.zip` with `PK`.
- Confirm the file landed on disk before moving on (`await-download.ps1`).
- `.alp` packs cannot be unpacked — the user must drag them into Live.

## Requirements

PowerShell 5.1+ (Windows) or PowerShell 7 (`pwsh`, macOS/Linux), plus `curl`. On
macOS and Linux `pwsh` is not installed by default — if it is missing, say so rather
than rewriting the scripts on the fly.
