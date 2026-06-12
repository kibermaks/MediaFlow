# Changelog

All notable MediaFlow changes are tracked here. Keep the newest release first and attach the matching DMG to the GitHub Release for self-updates.

## [0.7] - 2026-06-12

### Added
- Per-file Quality Controls master switch for saved file enhancements.
- Diagnostic Color Output selector for per-file image and video color output troubleshooting.
- `scripts/inspect-media-file.swift` for ImageIO, Core Image, and AVFoundation media diagnostics.

### Changed
- Mixed photo/video collages now render into a stable canvas color mode so SDR video does not wash out Display P3 photos.
- HDR-aware still image loading now tone-maps adaptive HDR material against display headroom.
- Brightness now follows the Auto Tone checkbox in both the UI and renderer.
- Quality profile loading now preserves compatibility with older saved profiles.

## [0.6] - 2026-06-01

### Changed
- Left and right arrow video seeking now supports modifier steps: Option steps one frame, Shift nudges one second, and Command jumps one minute.
- Enlarge and Reduce now support modifier steps: Option for fine sizing, Shift for smaller adjustments, and Command for coarse sizing.
- The Enlarge menu shortcut now displays as `+` instead of the physical `=` key.

## [0.5] - 2026-05-30

### Added
- Draggable A-B markers on the video timeline with live preview while adjusting loop points.
- Rotate 180 controls in the hover tools and Item menu.
- Local build metadata for non-release builds, including build number and linked worktree name when present.

### Changed
- What's New now uses the bundled changelog parser and a styled versioned layout.
- Video output uses lighter SDR buffers while preserving HDR/EDR buffers for wide-range material.
- Removed reverse Swing playback mode so videos and A-B segments stay in smooth forward Loop playback.

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
