# maxforlive-harvester

Bulk-harvest Max for Live devices from [maxforlive.com](https://maxforlive.com),
verify them by magic bytes, drop them where Ableton Live actually indexes them,
finish the **free** Gumroad checkouts for authors who moved distribution off the
site, and print a categorised catalogue of what you now own.

Built to survive the two things that break naive M4L scrapers: **Cloudflare**
(which 403s .NET HTTP clients) and the site's **HTTP 1015 rate limiter** (which
returns a short text body that looks exactly like "File not found", producing
hundreds of false negatives).

## Who it is for

* Producers who want the good free M4L devices without clicking 400 pages.
* Anyone rebuilding a User Library after a clean install.
* Agents/automation that need to add M4L devices on a user's behalf without
  spamming a site, stealing window focus, or spending money.

## Quickstart

```powershell
git clone <this repo> maxforlive-harvester
cd maxforlive-harvester
Copy-Item config.example.json config.json

.\scripts\detect-library.ps1 -List        # see which Live versions exist
.\scripts\detect-library.ps1              # write the real User Library path

.\scripts\list-devices.ps1 -Pages 5       # inventory
.\scripts\build-queue.ps1 -Take 50        # queue
.\scripts\run.ps1 -Install                # download + install (background this)
.\scripts\monitor.ps1                     # progress, pacing, ETA, errors

.\scripts\categorize.ps1                  # -> CATALOG.md
```

Then, for the devices whose files moved to a store front:

```powershell
.\scripts\gumroad-discover.ps1
.\scripts\gumroad-price-probe.ps1
.\scripts\gumroad-next.ps1                # one product at a time
.\scripts\gumroad-log-result.ps1 -Id <id> -Outcome free-purchased
```

Full documentation, including the `.amxd` container format, placement rules and
the troubleshooting table, lives in [SKILL.md](SKILL.md) (the same file doubles
as the agent skill definition).

## Why the User Library is detected, not assumed

`~/Documents` is frequently redirected into OneDrive or another drive. Writing
devices into `Documents\Ableton\User Library` when Live indexes
`OneDrive\Documents\Ableton\User Library` produces installs that "succeed" and
never appear. The detector reads Live's own indexer log:

```
%APPDATA%\Ableton\Live <VER>\Preferences\Indexer.txt
Configure: UserLibrary: '<path>' [User Library]
```

and warns when a second library exists somewhere else.

## What is and is not automated

| Automated | Manual by design |
| --- | --- |
| Catalogue scraping, paced downloads, magic-byte validation | `.alp` packs (drag into Live) |
| Zip extraction, build-tree quarantine, placement | Anything above 0.00 at Gumroad |
| Free Gumroad checkout navigation and price reading | Card details (never) |
| Device categorisation and catalogue generation | Account login walls |

## Gumroad: free only - legal and ethical note

This tool is designed to complete checkouts **only when the cart total is
0.00**. It reads the price from the product page, then verifies the cart total
before submitting, because a "$0+" (pay-what-you-want) listing can still default
to a non-zero amount - one observed case totalled 5.49.

It never enters payment details, never bypasses a price, never uses credentials
it was not given, and records anything above zero as `paid` (and does not buy
it). If an order requires a login to reach the download, it stops and reports
`blocked-login`.

Free downloads are free because the author chose to give them away. Respect the
author's licence: many devices are free for personal use only, and some are demos
of a paid product. Check before redistributing anything you download.

## Requirements

* PowerShell 5.1+ (Windows) or PowerShell 7 (macOS/Linux)
* `curl` (bundled with Windows 10+ and macOS)
* Ableton Live (started at least once, with Max for Live)
* A Gumroad-capable browser session, if you want the store-front step

## Repository layout

```
SKILL.md                 the skill + full documentation
config.example.json      copy to config.json
scripts/
  _common.ps1            config, paths, logging, magic bytes, pacing, JSON helpers
  detect-library.ps1     find the User Library from Live's indexer log
  list-devices.ps1       inventory maxforlive.com -> devices.json
  build-queue.ps1        devices.json -> queue.json
  run.ps1                paced download worker (+ -Install)
  install-m4l.ps1        validate + place .amxd / zip, quarantine build trees
  finish-item.ps1        browser download -> validate -> install, one device
  await-download.ps1     COMPLETE / COMPLETE-TMP / STALLED / NONE
  monitor.ps1            progress, pacing, ETA, errors
  inspect-amxd.ps1       ampf chunk walker + sidecar / dependency_cache audit
  categorize.ps1         categories + CATALOG.md
  gumroad-discover.ps1   store front link per gated device
  gumroad-price-probe.ps1 listed price, permalink, checkout URL
  gumroad-next.ps1       next free candidate (never purchases)
  gumroad-log-result.ps1 idempotent result ledger
```

## Disclaimer

**Not affiliated with, endorsed by, or supported by Ableton AG, Cycling '74,
maxforlive.com, or Gumroad.** Max for Live and Ableton Live are trademarks of
Ableton AG. This is an independent, unofficial helper that drives public web
pages; it uses no private APIs. Site markup and store front behaviour change
without notice - if a parser breaks, the selectors live in `list-devices.ps1`
and `gumroad-price-probe.ps1`.

Use it considerately: keep the pacing defaults, do not raise `maxDelay`/floor
values to hammer the site, and cache what you download instead of re-fetching.

## License

MIT - see [LICENSE](LICENSE).

---

## Incremental by default â€” it already knows what you have

The repo ships a baseline index so a repeat run costs minutes, not hours:

- `seed/known-devices.json` â€” **877 maxforlive.com devices** with the outcome already
  recorded for each (`downloaded`, `paid`, `gated`, `not-for-sale`, `blocked`, `untried`)
- `seed/sources.json` â€” the **24 non-maxforlive sources** already found: GitHub repos,
  Ableton `.alp` packs, and Gumroad items

Before harvesting anything, run:

```powershell
.\scripts\diff-known.ps1            # lists ONLY devices not already in the seed
.\scripts\diff-known.ps1 -UpdateSeed  # fold the new finds back in afterwards
```

Then fetch only the new ids. A full sweep is thousands of paced requests; a diff is
a handful of pages. If a user asks for something topical ("new granular devices",
"anything new for Push 2"), list first, then subtract the seed â€” names change, ids
don't, so filter on `id`.
