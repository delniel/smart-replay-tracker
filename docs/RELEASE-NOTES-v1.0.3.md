# Smart Replay Tracker v1.0.3

## What's new

- Added `Filename Template Override` for users who want the replay naming logic to follow the same OBS date/time template they already use in `Settings -> Advanced -> Recording -> Filename Formatting`
- Added `Keep MKV After Auto Remux` so you can choose whether to keep the original `mkv` after OBS creates the final `mp4`
- Improved active-app fallback logic so replay saves are less likely to stay stuck on the previous game's folder and name after switching to another game
- Updated the packaged plugin DLL and Lua script in the `release/` folder
- Expanded the configuration guide with new screenshots and clearer explanations for the new settings

## Upgrade notes

- Replace both files from the `release/` folder:
  - `smart-replay-tracker.dll`
  - `replay-file-organizer.lua`
- If you use a custom OBS filename format for Replay Buffer naming consistency, copy the same value into `Filename Template Override`
- If `Automatically remux to mp4` is enabled in OBS, turn on `Keep MKV After Auto Remux` only if you want to keep both files
