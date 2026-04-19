# Smart Replay Tracker v1.0.2

This release focuses on replay routing fixes and bundled file updates.

## Included

- `smart-replay-tracker.dll`
- `replay-file-organizer.lua`

## Changes in v1.0.2

- Fixed stale routing that could keep using the previous game's folder and file name
- Improved fallback behavior for OBS builds where Replay Buffer does not expose a reliable `saving` signal
- Improved final replay naming so the current filename template can be carried into the target stem
- Updated the bundled release files in `release/`
- Added documentation notes explaining why `mp4` may be the only final file when OBS `Auto Remux` is enabled

## Notes

- On some OBS builds, Replay Buffer still does not expose a reliable early `saving` signal
- The project continues to handle final replay naming after OBS finishes saving the file
- If `Auto Remux` is enabled, the final moved file may be `mp4` only
