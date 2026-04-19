# Smart Replay Tracker v1.0.1

This release focuses on documentation and project presentation.

## Included

- `smart-replay-tracker.dll`
- `replay-file-organizer.lua`

## Changes in v1.0.1

- Rewrote the repository documentation in English
- Added a dedicated configuration guide for the Lua script
- Added screenshots for the main script UI sections
- Expanded the explanation of:
  - `Priority Sources`
  - `Excluded Sources`
  - `Mappings`
  - how the script and plugin work together
- Added clearer background information about why this project exists and why Replay Buffer requires a plugin + script approach

## Notes

- On some OBS builds, Replay Buffer does not expose a reliable early `saving` signal.
- Because of that, the final replay rename happens after OBS writes the replay file.
- This is expected for this project design.
