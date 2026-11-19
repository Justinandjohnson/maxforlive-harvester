# Where things go, by platform

## Finding the User Library

**Do not assume `~/Documents/Ableton/User Library`.** Documents is commonly
redirected into OneDrive, iCloud or another drive, which produces installs that
"succeed" and never appear in Live.

Read Live's own indexer log and use the path it reports.

### Windows

```
%APPDATA%\Ableton\Live <VERSION>\Preferences\Indexer.txt
```

```powershell
Select-String -Path "$env:APPDATA\Ableton\Live*\Preferences\Indexer.txt" -Pattern 'UserLibrary:'
```

### macOS

```
~/Library/Preferences/Ableton/Live <VERSION>/Preferences/Indexer.txt
```

```bash
grep 'UserLibrary:' ~/Library/Preferences/Ableton/Live*/Preferences/Indexer.txt
```

The line you want looks like:

```
Configure: UserLibrary: '/path/to/User Library' [User Library]
```

That quoted path is the one to write into. If the log lists more than one library,
ask the user which is live rather than guessing.

## Destination folders

| What you have | Where it goes |
| --- | --- |
| Plain `.amxd` | `<UserLibrary>/Max for Live Devices/<Collection>/` |
| `.amxd` plus sibling `.js` / `.html` / `.json` | `<UserLibrary>/Presets/Max MIDI Effect/<Name>/` |
| A zip containing several devices | extract into its own folder under `Max for Live Devices/<Collection>/` |
| `.alp` Ableton Pack | nowhere — the user drags it into Live |

`<Collection>` is any folder name you choose; one per harvest keeps things tidy.

## Shell equivalents

The agent picks whichever matches the machine.

### Check the magic bytes

```bash
head -c 4 file.amxd        # macOS / Linux
```

```powershell
(Get-Content file.amxd -AsByteStream -TotalCount 4)   # PowerShell 7
[System.IO.File]::ReadAllBytes("file.amxd")[0..3]     # PowerShell 5.1
```

`ampf` = real device. `PK` = zip.

### Extract a zip

```bash
unzip -o archive.zip -d target/
rm -rf target/__MACOSX
```

```powershell
Expand-Archive -Path archive.zip -DestinationPath target -Force   # may fail on some M4L zips
```

If `Expand-Archive` throws, unpack entry by entry instead:

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$a = [System.IO.Compression.ZipFile]::OpenRead("archive.zip")
foreach ($e in $a.Entries) {
  if ([string]::IsNullOrEmpty($e.Name) -or $e.FullName -like '*__MACOSX*') { continue }
  $out = Join-Path "target" $e.FullName
  New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
  [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
}
$a.Dispose()
```

### Copy into the library

```bash
cp -R "Device.amxd" "/path/User Library/Max for Live Devices/Collection/"
```

```powershell
Copy-Item "Device.amxd" "$lib\Max for Live Devices\Collection\" -Force
```

## Confirm Live picked it up

Watch the indexer log for a scan of the folder you wrote into:

```bash
tail -20 ~/Library/Preferences/Ableton/Live*/Preferences/Indexer.txt
```

```powershell
Get-Content "$env:APPDATA\Ableton\Live*\Preferences\Indexer.txt" -Tail 20
```

If it did not appear, ask the user to right-click **User Library → Refresh
Browser**. No restart is normally needed — Live indexes via OS file events.
