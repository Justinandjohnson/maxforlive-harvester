# maxforlive-harvester

[![license](https://img.shields.io/github/license/Justinandjohnson/maxforlive-harvester)](LICENSE)
![platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)
![deps](https://img.shields.io/badge/dependencies-none-brightgreen)

**An agent skill that fills your Ableton User Library with free Max for Live devices — without clicking 400 pages.**

![What your agent does: list, diff, download, verify, install, confirm](docs/pipeline.svg)

## What this is

It's a **skill file**. Your agent reads it and does the work itself, using the
browser and shell tools it already has.

| File | Role |
| --- | --- |
| `SKILL.md` | The instructions. This is the skill. |
| `reference/platform-paths.md` | Where devices go on Windows, macOS and Linux |
| `seed/known-devices.json` | 877 devices already indexed, so it skips what you have |

That's all of it. **No scripts, no installer, no dependencies, nothing to run.** If
your agent can browse the web and move a file, it can do this.

## Install

```bash
npx skills add Justinandjohnson/maxforlive-harvester
```

Copies the skill into `.agents/skills/`, which Claude Code, Codex, Cursor and
OpenCode all read. Add `-g` to install for every project.

<details>
<summary>Other ways to install</summary>

- **Claude Code / OpenCode:** copy the `skills/maxforlive-harvester/` folder into `~/.claude/skills/` or `~/.config/opencode/skills/`
- **Codex:** copy into `~/.agents/skills/` — `AGENTS.md` at the repo root is the entry point
- **Any other agent:** point it at `SKILL.md`; that file is the whole thing

</details>

Then just ask:

```text
Use maxforlive-harvester to refresh my Max for Live library
```

## Use when

- your User Library was wiped and you want the good free devices back
- you want releases since last time, not the whole catalogue again
- a previous attempt said "File not found" for everything — that's usually the
  site's rate limiter, not missing files
- you need M4L devices added without spending money or tripping a bot wall

## What it does

| You want | You say | You end up with |
| --- | --- | --- |
| Everything free, from scratch | "harvest the free M4L devices" | A full library, every file verified |
| Only what's new | "what's new since last time" | A short list of releases, then just those |
| Devices whose authors moved to Gumroad | "get the free ones off Gumroad" | The **$0** ones only — it never buys |
| To know what you own | "catalogue my M4L devices" | A list sorted by what each one does |

It works the same on Windows, macOS and Linux, because it uses the shell you
already have rather than shipping its own.

## It knows what it's doing

877 devices are indexed with their outcome already known, so it never re-fetches
and never mistakes a paywall for a failure.

![What the 877-device seed already knows](docs/seed-outcomes.svg)

**263 of those were behind a real price and were deliberately not bought.** Checkouts
happen only when the cart total is 0.00 — it checks the cart, not the listing,
because a "$0+" item was seen totalling $5.49. It asks you for your email rather
than shipping with one baked in.

![410 installed devices, by category](docs/categories.svg)

## Requirements

- An agent with **browser or HTTP access** and **shell access** — Claude Code, Codex, Cursor, OpenCode, or anything similar
- **Ableton Live** with Max for Live, started at least once

That's it. No runtime, no package install, no PowerShell.

<details>
<summary>Why it reads your live's indexer log instead of guessing the path</summary>

`~/Documents` is often redirected into OneDrive or iCloud. Writing devices into
`Documents/Ableton/User Library` while Live indexes `OneDrive/Documents/...`
produces installs that succeed and never appear. The skill tells the agent to read
Live's own indexer log and use the path it reports — see
`reference/platform-paths.md`.

</details>

<details>
<summary>Related work, and why this isn't an Ableton Extension</summary>

- [thereplicants/ableton-package-manager](https://github.com/thereplicants/ableton-package-manager) — manages devices you already have; does not fetch them
- [mgarbvs/m4l-github-updater](https://github.com/mgarbvs/m4l-github-updater) — updates installed devices from GitHub
- [Ronvaknins/ableton-extensions-skill](https://github.com/Ronvaknins/ableton-extensions-skill) — builds Ableton Extensions

Harvesting is HTTP, rate limiting and file validation — all of which work with Live
closed. An Extension would add a Node ≥24 toolchain and a beta SDK to save about
thirty seconds.

</details>

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Ableton AG, Cycling '74, maxforlive.com or Gumroad.
