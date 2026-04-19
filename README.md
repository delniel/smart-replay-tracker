# Smart Replay Tracker

Windows plugin + Lua script for OBS Studio that organize Replay Buffer clips into game folders with cleaner names.

## What is included

- `release/smart-replay-tracker.dll` - OBS plugin
- `release/replay-file-organizer.lua` - OBS Lua script

## What it does

- Tracks the last relevant app before a replay save
- Matches that app against your OBS sources
- Applies your mappings to produce cleaner game names
- Moves the final replay into the correct folder after save
- Avoids restarting Replay Buffer on every window switch

## Why this project exists

I wanted OBS Replay Buffer clips to behave more like the "instant replay" experience people expect from tools such as NVIDIA ShadowPlay or AMD ReLive: save a clip and get a meaningful game-based file name automatically.

Renaming **normal recordings** is not the hard part. There are already scripts that can change the recording name before a standard OBS recording starts, because OBS exposes a clean moment before the file is created.

Replay Buffer is different. On many OBS builds, there is no reliable early hook for changing the final Replay Buffer file name and folder before OBS writes the file. The most obvious workaround is:

1. let OBS save `Replay ...`
2. find the newest saved file afterwards
3. rename or move it from a script

That approach can work, but it is fragile:

- timing races
- file locks
- remux timing issues
- unreliable "find the latest file" logic

That is why this project uses **two parts together**:

- the plugin handles foreground app tracking, replay path detection, and safe file moving on Windows
- the script handles OBS-side logic: source selection, exclusions, mappings, folder/name generation, and formatting preview

In short: the existing idea of "rename OBS output with a script" already works for normal recording. This project extends that idea to Replay Buffer by pairing the script with a native plugin so the saved replay file can be moved and renamed much more reliably.

## Why there are two files

The project is split into two parts on purpose:

- The plugin handles Windows-side work: foreground app tracking, replay path detection, and safe file moving after save.
- The script handles OBS-side logic: source selection, exclusions, mappings, folder/name generation, and formatting preview.

Use both files together.

## Tested environment

- Windows 10/11 x64
- OBS Studio 64-bit
- Built and tested around OBS 31.1.1

## Installation

1. Close OBS.
2. Copy `release/smart-replay-tracker.dll` to your OBS plugins folder.

   - Standard install:
     `C:\Program Files\obs-studio\obs-plugins\64bit\`
   - Steam install example:
     `E:\Steam\steamapps\common\OBS Studio\obs-plugins\64bit\`

3. Start OBS.
4. Open `Tools -> Scripts`.
5. Add `release/replay-file-organizer.lua`.
6. Configure the script.

Detailed setup guide with screenshots:

- [Script configuration guide](docs/SCRIPT-CONFIGURATION.md)

## Basic usage

1. Start Replay Buffer in OBS.
2. Play or switch between apps as usual.
3. Save the replay with your OBS hotkey.
4. OBS may first create a temporary `Replay ...` file.
5. The plugin then moves the final file into the target folder with the generated name.

## Notes

- On some OBS builds, Replay Buffer does not expose a usable early `saving` signal.
- Because of that, the final rename happens after OBS saves the replay file.
- This is expected behavior for this project.

## Repository structure

```text
release/
  smart-replay-tracker.dll
  replay-file-organizer.lua
docs/
  SCRIPT-CONFIGURATION.md
screenshots/
README.md
LICENSE
.gitignore
```

## License

MIT
