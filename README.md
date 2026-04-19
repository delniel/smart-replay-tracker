# Smart Replay Tracker

Windows plugin + Lua script for OBS Studio that rename and sort Replay Buffer clips into game folders.

## What is included

- `release/smart-replay-tracker.dll` - OBS plugin
- `release/replay-file-organizer.lua` - OBS Lua script

## What it does

- Tracks the last relevant active app before a replay save
- Matches that app against your OBS sources and mappings
- Saves the final replay clip into the correct folder with a cleaner name
- Works without restarting Replay Buffer on every window switch

## Why there are two files

The plugin and the script work together.

- The plugin tracks the foreground app and safely moves the saved replay file on Windows.
- The script handles OBS-side logic: source matching, mappings, folder/name generation, and move requests.

Use both files together. The script is not meant to be used without the plugin.

## Tested environment

- Windows 10/11 x64
- OBS Studio 64-bit
- Built and tested around OBS 31.1.1

## Installation

1. Close OBS.
2. Copy `release/smart-replay-tracker.dll` to your OBS plugins folder:

   - Standard install:
     `C:\Program Files\obs-studio\obs-plugins\64bit\`
   - Steam install example:
     `E:\Steam\steamapps\common\OBS Studio\obs-plugins\64bit\`

3. Start OBS.
4. Open `Tools -> Scripts`.
5. Add `release/replay-file-organizer.lua`.
6. Configure your source lists and mappings inside the script UI.

## Basic usage

1. Start Replay Buffer in OBS.
2. Play or switch between apps as usual.
3. Save the replay with your OBS hotkey.
4. OBS may first write a temporary `Replay ...` file.
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
screenshots/
README.md
LICENSE
.gitignore
```

## Add screenshots later

Put your screenshots into the `screenshots/` folder and add them to this README when you want.

## License

MIT
