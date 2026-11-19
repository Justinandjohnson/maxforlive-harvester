# maxforlive-harvester

**An agent skill that fills an Ableton Live User Library with free Max for Live devices — without clicking 400 pages.**

It walks [maxforlive.com](https://maxforlive.com), respects the site's rate limit, verifies every file by magic bytes, drops each device where Live actually indexes it, finishes the **free** Gumroad checkouts for authors who moved distribution off the site, and prints a categorised catalogue of what you now own.

Built to survive the two things that quietly break naive M4L scrapers:

- **Cloudflare** — 403s `.NET` HTTP clients; this uses `curl` instead.
- **HTTP 1015 rate limiting** — returns a short text body that looks *exactly* like "File not found". Ignore it and you get hundreds of false negatives, and think everything is gone when you were only throttled.

![How a harvest runs](docs/pipeline.svg)

---

## What you get

| Ships with this repo | |
| --- | --- |
| **877 devices** | a baseline index of maxforlive.com with the outcome already recorded for each |
| **24 sources** | GitHub repos, Ableton `.alp` packs and Gumroad items already found and catalogued |
| **16 scripts** | detection, inventory, queue, paced worker, installer, Gumroad flow, monitor, categoriser |
| **A real catalogue** | [`examples/CATALOG.md`](examples/CATALOG.md) — 410 devices sorted into 10 categories |
| **Full documentation** | [`SKILL.md`](SKILL.md) — the playbook, `.amxd` internals, and an 18-row troubleshooting table |

## Quickstart

```powershell
git clone https://github.com/Justinandjohnson/maxforlive-harvester.git
cd maxforlive-harvester
Copy-Item config.example.json config.json

.\scripts\detect-library.ps1 -List       # which Live versions exist on this machine
.\scripts\detect-library.ps1             # write the real User Library path to config.json

.\scripts\diff-known.ps1                 # what is NEW since the shipped seed
.\scripts\list-devices.ps1 -Pages 5      # or take a fresh inventory
.\scripts\build-queue.ps1 -Take 50       # queue up work
.\scripts\run.ps1 -Install               # download + install (run this in the background)
.\scripts\monitor.ps1                    # progress, pacing, ETA, errors

.\scripts\categorize.ps1                 # -> CATALOG.md, next to your devices
```

Devices whose files have moved to a store front:

```powershell
.\scripts\gumroad-discover.ps1           # find the store link per gated device
.\scripts\gumroad-price-probe.ps1        # read the listed price + checkout URL
.\scripts\gumroad-next.ps1               # next free candidate (never purchases)
.\scripts\gumroad-log-result.ps1 -Id <id> -Outcome free-purchased
```

## How it is laid out

```
SKILL.md                  the agent skill AND the full manual (read this second)
README.md                 you are here
examples/CATALOG.md       real categorised output from a 410-device library
seed/
  known-devices.json      877 devices + outcome for each  <- the time saver
  sources.json            24 non-maxforlive sources already found
scripts/
  _common.ps1             config, paths, logging, magic bytes, pacing, JSON helpers
  detect-library.ps1      find the User Library from Live's own indexer log
  diff-known.ps1          list ONLY devices missing from the seed
  list-devices.ps1        inventory maxforlive.com -> devices.json
  build-queue.ps1         devices.json -> queue.json
  run.ps1                 paced download worker (+ -Install)
  install-m4l.ps1         validate + place .amxd / zip, quarantine build trees
  finish-item.ps1         browser download -> validate -> install, one device
  await-download.ps1      COMPLETE / COMPLETE-TMP / STALLED / NONE
  monitor.ps1             progress, pacing, ETA, errors
  inspect-amxd.ps1        ampf chunk walker + sidecar / dependency_cache audit
  categorize.ps1          categories + CATALOG.md
  gumroad-discover.ps1    store front link per gated device
  gumroad-price-probe.ps1 listed price, permalink, checkout URL
  gumroad-next.ps1        next free candidate (never purchases)
  gumroad-log-result.ps1  idempotent result ledger
```

**Start with `diff-known.ps1`, not `list-devices.ps1`.** The seed already knows what has been done, so a refresh costs minutes instead of hours.

---

## Incremental by default — it already knows what you have

`seed/known-devices.json` carries **877 devices** with the outcome already recorded:

| `outcome` | Meaning | What to do |
| --- | --- | --- |
| `downloaded` | already fetched and installed | skip |
| `paid` | behind a real price | skip, unless the user says they'll pay |
| `gated` | no file on the site and no link | skip unless the page changed |
| `not-for-sale` | listing withdrawn | skip |
| `blocked` / `blocked-login` | needed an address or an account | ask the user, don't retry blindly |
| `untried` | known, never attempted | fair game |

```powershell
.\scripts\diff-known.ps1                # only devices NOT in the seed
.\scripts\diff-known.ps1 -Pages 40      # reach further back in time
.\scripts\diff-known.ps1 -UpdateSeed    # fold the new finds back in
```

A full sweep is thousands of paced requests. A diff is a handful of pages. Filter on **`id`**, not name — device names get edited, ids don't.

![What the seed already knows](docs/seed-outcomes.svg)

## Why the User Library is detected, not assumed

`~/Documents` is frequently redirected into OneDrive or another drive. Writing devices into `Documents\Ableton\User Library` while Live indexes `OneDrive\Documents\Ableton\User Library` produces installs that *succeed* and never appear in the browser. The detector reads Live's own indexer log instead:

```
%APPDATA%\Ableton\Live <VER>\Preferences\Indexer.txt
Configure: UserLibrary: '<path>' [User Library]
```

…and warns when a second User Library exists somewhere else. This is the single most common way an M4L install silently fails.

## Gumroad: free only — legal and ethical note

This tool completes a checkout **only when the cart total is 0.00**.

It reads the price from the product page, then **re-verifies the cart total** before submitting — because a "$0+" pay-what-you-want listing can still default to something non-zero. One observed case read "$0+" on the listing but totalled **$5.49** at checkout.

It never enters payment details, never bypasses a price, never uses credentials it was not given, and records anything above zero as `paid` without buying it. If an order needs a login to reach the download, it stops and reports `blocked-login`. It asks the user for their email — it never ships with one baked in.

Free downloads are free because the author chose to give them away. **Respect the licence** — many are personal use only, and some are demos of a paid product.

## What is and is not automated

| Automated | Manual by design |
| --- | --- |
| Catalogue scraping, paced downloads, magic-byte validation | `.alp` packs (drag into Live) |
| Zip extraction, build-tree quarantine, placement | Anything above 0.00 at Gumroad |
| Free Gumroad checkout navigation and price reading | Card details (never) |
| Device categorisation and catalogue generation | Account login walls |

## Requirements

- **PowerShell 5.1+** (Windows) or **PowerShell 7** (`pwsh`, macOS/Linux)
- **curl** — bundled with Windows 10+ and macOS
- **Ableton Live**, started at least once, with Max for Live
- A browser session with a Gumroad login, if you want the store-front step

> **Platform status:** developed and tested on **Windows**. The macOS preferences path is implemented and the scripts are portable, but no macOS run has been recorded. If you hit a problem there, an issue with your error output is genuinely useful.

---

## Related work

None of these do what this does, but they are the closest neighbours:

- **[thereplicants/ableton-package-manager](https://github.com/thereplicants/ableton-package-manager)** — an experimental package manager for the Max for Live ecosystem. Manages devices you already have; it does not find or fetch them from the web.
- **[mgarbvs/m4l-github-updater](https://github.com/mgarbvs/m4l-github-updater)** — an Ableton Extension that checks GitHub for newer releases of devices you have installed. Covers the update half of an incremental workflow, scoped to GitHub.
- **[Ronvaknins/ableton-extensions-skill](https://github.com/Ronvaknins/ableton-extensions-skill)** — an agent skill for building Ableton Live extensions with the Extensions SDK.

### Why this is not an Ableton Extension

An Ableton Extension is an offline editing/automation layer that runs *inside* Live and acts on the Set when a user triggers a command. Harvesting is not that — it is HTTP, rate limiting, file validation and filesystem placement, all of which work with Live closed.

Wrapping it in an extension would add a Node (≥24.14.1) toolchain and an SDK still in beta, to save roughly thirty seconds: Live indexes the User Library automatically via OS file events, so no restart is normally needed.

If there is demand for a right-click "check for new devices" entry inside Live, an extension that *calls* these scripts is the sensible shape — not a rewrite in TypeScript.

## What the output looks like

See **[examples/CATALOG.md](examples/CATALOG.md)** — a real catalogue from a 410-device library, grouped into Synths, Drums & Percussion, Samplers & Granular, Sequencers, Chords & Harmony, Modulation, Audio Effects, Push & Session Control, Utilities and Experimental, each with *what it does* and *reach for it when*.

Devices marked *inferred from name* are undocumented — the listing had no usable description. That's flagged rather than guessed over.

![Installed devices by category](docs/categories.svg)

## Disclaimer

**Not affiliated with, endorsed by, or supported by Ableton AG, Cycling '74, maxforlive.com, or Gumroad.** Max for Live and Ableton Live are trademarks of Ableton AG. This is an independent, unofficial helper that drives public web pages and uses no private APIs. Site markup and store-front behaviour change without notice — if a parser breaks, the selectors live in `list-devices.ps1` and `gumroad-price-probe.ps1`.

Use it considerately: keep the pacing defaults, don't raise `maxDelay` to hammer the site, and cache what you download instead of re-fetching.

## License

MIT — see [LICENSE](LICENSE).
