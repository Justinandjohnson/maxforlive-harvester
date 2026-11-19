# Where things go, by platform

## Finding the User Library

**Do not assume the Documents path.** It is commonly redirected into OneDrive or
iCloud, which produces installs that "succeed" and never appear in Live.

Read Live's own indexer log and use the path it reports. The two platforms store it
in different shapes — note the nested `Preferences` folder on Windows and the flat
one on macOS.

### Windows

```
%APPDATA%\Ableton\Live <VERSION>\Preferences\Indexer.txt
```

```powershell
Select-String -Path "$env:APPDATA\Ableton\Live*\Preferences\Indexer.txt" -Pattern 'UserLibrary:'
```

### macOS

```
~/Library/Preferences/Ableton/Live <VERSION>/Indexer.txt
```

```bash
grep 'UserLibrary:' ~/Library/Preferences/Ableton/Live*/Indexer.txt
```

### Reading the line

Live 12 writes it with quotes and a tag:

```
Configure: UserLibrary: '/path/to/User Library' [User Library]
```

Live 11 writes it unquoted with no tag:

```
... Configure: UserLibrary: /Users/you/OneDrive/Documents/Ableton/User Library
```

Take everything after `UserLibrary: ` to end of line, then strip surrounding quotes
and any trailing `[User Library]`. Do not anchor on the bracket — Live 11 has none.

### Which version, and which library

- Several `Live <VERSION>` folders are normal, including betas like `12.0b23`.
  **Pick the highest non-beta version.** If a wildcard glob returns several files,
  do not interleave them — pick one.
- If the log lists **more than one library**, ask the user which is live. Do not guess.

### Defaults if the log cannot be read

| Platform | Default |
| --- | --- |
| macOS | `~/Music/Ableton/User Library` |
| Windows | `%USERPROFILE%\Documents\Ableton\User Library` |

Use these only as a fallback, and say you did.

## Destination folders

| What you have | Where it goes |
| --- | --- |
| Instrument with support files | `<UserLibrary>/Presets/Instruments/Max Instrument/<Name>/` |
| Audio effect with support files | `<UserLibrary>/Presets/Audio Effects/Max Audio Effect/<Name>/` |
| MIDI effect with support files | `<UserLibrary>/Presets/MIDI Effects/Max MIDI Effect/<Name>/` |
| Plain `.amxd`, no siblings | `<UserLibrary>/Max for Live Devices/<Collection>/` |
| A zip of several devices | its own folder under `Max for Live Devices/<Collection>/` |
| `.alp` Ableton Pack | nowhere — the user drags it onto Live |

"Support files" means a `.js`, `.html` or `.json` sitting next to the `.amxd`. The
folder must travel with the device or it will not load.

`<Collection>` is any folder name you choose; one per harvest keeps things tidy.
**Create it before copying** — `mkdir -p` / `New-Item -ItemType Directory -Force`.

## Shell equivalents

### Check the magic bytes

The goal is to see `ampf` (device), `PK` (zip) or `pl-a` (pack). Make sure your
command prints **characters**, not byte numbers.

```bash
head -c 4 downloads/<id>.bin        # macOS -> prints ampf
```

```powershell
# Windows, PowerShell 5.1 and 7 both -> prints ampf
# Resolve-Path matters: .NET resolves against the PROCESS working directory,
# not the shell's, so a bare relative name fails after a cd - and the error
# looks like a broken download.
$p = (Resolve-Path "downloads\<id>.bin").Path
[System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($p)[0..3])
```

Do **not** run `ReadAllBytes(...)[0..3]` on its own — it prints `97,109,112,102`,
which looks corrupt but is `ampf`. And `-AsByteStream` only exists in PowerShell 7;
on 5.1 it errors.

### Extract a zip

```bash
unzip -o archive.zip -d target/
rm -rf target/__MACOSX
```

```powershell
Expand-Archive -Path archive.zip -DestinationPath target -Force   # may fail on M4L zips
```

If `Expand-Archive` throws — it often does on these — unpack entry by entry:

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = (Resolve-Path "archive.zip").Path
$a = [System.IO.Compression.ZipFile]::OpenRead($zip)
foreach ($e in $a.Entries) {
  if ([string]::IsNullOrEmpty($e.Name) -or $e.FullName -like '*__MACOSX*') { continue }
  $out = Join-Path "target" $e.FullName
  New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
  [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
}
$a.Dispose()
```

### Copy into the library

Set the path from the indexer log first, then create the folder, then copy.

```bash
lib="$HOME/Music/Ableton/User Library"          # <- from the indexer log
mkdir -p "$lib/Max for Live Devices/Collection"
cp -R "Device.amxd" "$lib/Max for Live Devices/Collection/"
```

```powershell
$lib = "C:\path\from\indexer\log"                # <- from the indexer log
$dest = Join-Path $lib "Max for Live Devices\Collection"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item "Device.amxd" $dest -Force
```

## Confirm Live picked it up

Watch the indexer log for a scan of the folder you wrote into.

```bash
tail -20 ~/Library/Preferences/Ableton/Live*/Indexer.txt
```

```powershell
Get-Content (Get-ChildItem "$env:APPDATA\Ableton\Live*\Preferences\Indexer.txt" |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName -Tail 20
```

If it did not appear, ask the user to right-click **User Library → Refresh
Browser**. No restart is normally needed — Live indexes via OS file events.
