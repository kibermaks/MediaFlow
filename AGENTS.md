## Imported Claude Cowork project instructions

## Project memory

- This is a native macOS SwiftPM app: AppKit shell, Metal renderer, AVFoundation playback, and generated `.app` bundle.
- Build with `./scripts/build-native-app.sh` from the repo root. The script is the source of truth for bundle metadata, document types, release flags, strip, and signing.
- Bundle version metadata comes from `scripts/build-native-app.sh` defaults or explicit environment overrides.
- Public app name is `MediaFlow`; internal SwiftPM package/target is still `ImageViewerNative`.
- Do not hand-edit `MediaFlow.app/Contents/Info.plist` for permanent changes. Edit `scripts/build-native-app.sh`, rebuild, then verify the generated plist.
- Create local DMGs with `./scripts/create-dmg.sh` and verify with `./scripts/verify-dmg.sh`. The DMG script writes the Finder background/drag arrow by default; keep that background light because Finder draws icon labels in black. Use `SKIP_FINDER_LAYOUT=true` only when Finder AppleScript is blocked. `dmg_output/` is ignored and should be uploaded to GitHub Releases, not committed.
- Public release signing is supported via `SIGN_IDENTITY="Developer ID Application: ..."` and `./scripts/notarize.sh`.
- Finder Open With support requires both generated `CFBundleDocumentTypes` and AppDelegate open-file/open-URL handlers.
- App launch should stay clean by default. The previous auto-restore behavior is now manual via File -> Open Last Closed Session; users can delete it with File -> Forget Last Closed Session, and empty sessions should not overwrite the saved last non-empty playback.
- Icon generation rules live in `docs/ICON_GENERATION.md`; follow the SessionFlow-style cyan/violet glass Icon Composer language.
- SwiftPM builds may warn about AVFoundation metadata deprecations in `loadVideo(url:)`; that is a known warning, not a release blocker.
- Generated `.app` bundles are ignored; do not commit them. Put DMG/ZIP binaries in GitHub Releases.
- The repository has an MIT license. For public DMGs, use Developer ID signing/notarization instead of ad-hoc signing.
- Do not change GitHub repository visibility unless the user explicitly asks for that exact step.
- Longer repeatable build notes live in `BUILD.md`.
