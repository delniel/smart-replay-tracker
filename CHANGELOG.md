# Changelog

All notable changes to this project will be documented in this file.

## v1.0.3

- Added `Filename Template Override` for custom OBS date/time filename patterns
- Added `Keep MKV After Auto Remux` so users can keep both the original `mkv` and the final `mp4`
- Improved replay app selection so the project is less likely to keep using the previous game's folder and name after switching apps
- Updated the bundled DLL and Lua script in `release/`
- Expanded the documentation with new screenshots and setup details for the new options

## v1.0.2

- Fixed stale replay routing when OBS does not expose a working `saving` signal
- Improved fallback logic so the script is less likely to keep using the previous game's folder and name
- Added support for carrying the current filename template into the final replay target stem
- Updated the bundled DLL and Lua script in `release/`
- Clarified `Auto Remux` behavior in the documentation

## v1.0.1

- Rewrote the main documentation in English
- Added a dedicated script configuration guide
- Added screenshots for the script UI
- Expanded the explanation of `Excluded Sources`, `Mappings`, and the overall config flow
- Clarified the reason the project uses both a plugin and a Lua script

## v1.0.0

- Initial public release
- Included `smart-replay-tracker.dll`
- Included `replay-file-organizer.lua`
- Added the initial README and repository structure
