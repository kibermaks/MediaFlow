# Changelog

All notable MediaFlow changes are tracked here. Keep the newest release first and attach the matching DMG to the GitHub Release for self-updates.

## [0.4] - 2026-05-30

### Added
- Debug Information overlay from the View menu with render FPS and MediaFlow CPU usage.
- Brightness boost slider that adjusts exposure, shadows, midtone contrast, vibrance, and highlight rolloff together.
- HDR-aware image loading and adaptive HDR handling for gain-map material.
- Photos import collection browser and richer import panel status UI.

### Changed
- Frame interpolation now guards against HDR/noisy frame shimmer and applies quality processing before slow-motion blending.
- Speed changes, seeks, loop jumps, and scrubbing reset temporal frame history to avoid stale-frame artifacts.
- Quality Controls now uses compact custom switches, segmented sampling controls, and custom sliders.
- A-B controls now act on the selected video without unexpectedly changing selection.
- Removed reverse Swing playback mode so videos and A-B segments stay in smooth forward Loop playback.

## [0.3] - 2026-05-29

### Added
- Flow Library for keeping a larger media pool than the visible wall.
- Maximum visible item controls for TV and spare-screen memory-wall layouts.
- Round-robin and random library rotation, including optional duplicate random slots.
- Photos import from the File menu.
- About, What's New, and Check for Updates menu dialogs.
- GitHub Releases update checks and self-install flow for DMG or ZIP release assets.

### Changed
- Release builds now bundle this changelog so the installed app can show matching notes offline.

## [0.2] - 2026-05-28

### Added
- Clean launch behavior with manual restore from File -> Open Last Closed Session.
- File -> Forget Last Closed Session.
- Recent Playbacks menu management.
- DMG packaging and verification scripts modeled after SessionFlow.

### Changed
- Renamed the distributed app bundle to MediaFlow.

## [0.1] - 2026-05-28

### Added
- Native AppKit and Metal media wall for local images and videos.
- Drag-and-drop ingest, file picker ingest, Finder Open With support, saved playback files, and local playback controls.
