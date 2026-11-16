# Pocket Editing Instrument: Phase 0 + Phase 1 vertical slice

`CLAUDE.md` is the source of truth. This build covers **Phase 0** (an app shell, design tokens and basic components) and the **smallest working slice of Phase 1**: Photos/Files import, a clip sequence you can reorder, whole-sequence playback, Explore with a filmstrip, in/out trimming, undo/redo, persistence, and 9:16 H.264 export.

The UI is deliberately plain. It is meant for functional testing, and the final photographic-instrument look comes later (see `DesignReferences/`, which is art direction only).

> **Build status (2026-11-16):** builds in Xcode with no Swift warnings, all EditCore tests pass, and swift-format lint is clean. It has been tested in the iPhone 17 Pro simulator. It has **not** been tested on a physical iPhone yet; see the device checklist below.

## Requirements
- macOS with **Xcode 16** or later (iOS 17 SDK minimum; iOS 18 SDK recommended).
- **XcodeGen** to generate the `.xcodeproj` from `project.yml`.
- An iPhone running iOS 17+ for device testing. The Simulator works too, using the built-in **Demo clips**.

## Run it
```bash
cd PocketInstrument
brew install xcodegen          # once
xcodegen generate
open PocketInstrument.xcodeproj
```
In Xcode, open target **PocketInstrument**, go to **Signing & Capabilities**, choose your Team, pick your iPhone or a simulator, and press **Run**.

Core logic tests don't need the simulator:
```bash
cd Packages/EditCore && swift test
```

### Lint
Style rules live in `.swift-format` (4-space indent, 120 columns). Every app build runs a swift-format lint step that reports issues as Xcode warnings without failing the build. To lint or auto-fix from the terminal:
```bash
xcrun swift-format lint -r PocketInstrument Packages
xcrun swift-format format -i -r PocketInstrument Packages
```
`PocketInstrument.xcodeproj` is generated from `project.yml`. After editing `project.yml`, run `xcodegen generate` again.

## Architecture
```
Packages/EditCore/            Pure Swift with no AVFoundation, unit-tested
  MediaTime.swift             rational time (value/timescale), exact across timescales
  Model.swift                 SourceAsset, TimelineClip, AudioTrack, AutomationPoint,
                              LoopRange, ExportSettings, Project (versioned schema)
  SequenceMap.swift           source ↔ clip-local ↔ composition ↔ audio-reference time
  Commands.swift              EditingCommand protocol + Add/Move/Remove/Duplicate/Trim/…
  UndoStack.swift             snapshot undo/redo
  ProjectStore.swift          JSON project folders, atomic saves, media adoption
PocketInstrument/
  App/                        @main
  Design/                     Theme tokens, InstrumentButtonStyle, TimecodeText, GlassChip, LED, Haptics
  Media/                      CompositionBuilder (shared by preview and export), PlaybackEngine,
                              MediaImporter, ThumbnailCache, ExportService, DemoMediaGenerator
  Library/                    Project library: create, open, rename, delete
  Workspace/                  WorkspaceModel + one workspace with Arrange / Explore decks, ExportSheet
```

Key decisions:
- **Non-destructive editing.** A clip stores `sourceRange` and `speed`, and the original file is never modified. Imports are copied into `Application Support/Projects/<id>/Media/` and referenced by a relative name, because Photos only hands the app a temporary copy. Each import is moved into place, not copied twice.
- **WYSIWYG.** Preview and export both call `CompositionBuilder.build`. It renders the composition at 1080×1920 and applies each clip's preferred transform, with Fill (crop) or Fit (letterbox) framing.
- **Undo history is clean.** A trim drag shows a draft range live but commits a single undo step when you let go.
- **Missing media** keeps its slot as black, so the timing of everything else never shifts.

## What works
Status is *Implemented* where the code exists and works in the simulator. Device testing is still pending.

| Area | Status |
|---|---|
| Project library: create, open, rename, delete (with confirm), thumbnails, recent-first | Implemented |
| Import from Photos (multi-select, `.current` encoding so files aren't transcoded) and Files | Implemented |
| Demo clips (generated landscape, portrait and square test videos with burned-in timecode and frame number) | Implemented |
| Arrange: clip tiles; tap to select and cue; long-press-drag to reorder; VoiceOver Move left/right | Implemented |
| Arrange: duplicate, remove, Fill/Fit toggle, play whole sequence (loops), loop the selected clip | Implemented |
| Explore: whole-source filmstrip, drag to scrub, ±1 frame, In/Out keys, draggable handles, loop in/out | Implemented |
| Undo / redo for every edit | Implemented |
| Autosave (debounced, and on backgrounding) and reopen with order, trims and framing intact | Implemented |
| Export 9:16 1080×1920 H.264 MP4 30 fps, silent option, progress, cancel, Save to Photos, Share | Implemented |
| Speed | Stored in the model and honoured by composition and export; no UI yet (Phase 4) |
| Mix state: reference music from Files or from a video's sound, cached waveform, drag/nudge alignment | Phase 2: built, untested in the UI |
| Clip and music faders (live while playing, one undo step per move) | Phase 2: built, untested in the UI |
| Loop region bracket on the sequence ruler (Arrange and Mix), snaps to clip edges | Phase 2: built, untested in the UI |
| Release sound policy (clips + music, clips only, music only, silent) and music sync note | Phase 2: built, untested in the UI |
| Volume automation, dial, motion | Not started (later phases, by design) |

## Device test checklist (please report back)
1. Create a project, add **Demo clips**, and play. Does the sequence play A → B → C and loop?
2. Check framing: B (portrait) should fill the frame, and A (landscape) should be cropped to its centre. Toggle **Fit** on A to see the letterbox.
3. Long-press a tile and drag to reorder. Then undo and redo.
4. **Explore** clip A: scrub, step frames, then drag the In/Out handles. The burned-in frame number shows exactly where you are. Press **In** and **Out** at the playhead, and turn on Loop.
5. Return to **Arrange**. Is the clip shorter, and does the sequence still play smoothly?
6. Import 3+ real videos from Photos, including a long one and an HEVC/HDR one. Note the import time.
7. Force-quit and relaunch, then reopen the project. Are the order and trims intact?
8. Export with clip audio on and then off. Save to Photos, check that the frames match the preview, and confirm the silent version is silent.
9. Use the app with VoiceOver for a minute. Can you select, explore and trim?

## Preview vs export
- Preview always plays clips + music at the Mix levels. The Release sound policy only changes the exported file.
- Music is trimmed to the sequence. It never plays before the first frame or after the last.

## Known gaps / risks to watch
- **Not yet tested on a physical iPhone.** Photos import, HDR footage, touch feel and export quality need a real device.
- Export uses `AVAssetExportSession.exportAsynchronously`, which is deprecated on iOS 18 but works. It should move to `export(to:as:)` in Phase 5.
- Rebuilding the composition after an edit briefly reloads the player. This is fine for Phase 1, and smoothing it is a later optimisation.
- HDR sources are exported as SDR H.264 by the HighestQuality preset, so colours may shift. This needs checking on device.
- Pinch-to-zoom in the filmstrip isn't implemented yet. For long clips, precise trimming relies on frame-step and the In/Out keys.
- Deleting a clip keeps its media file, so undo still works. Unused media is only removed when the whole project is deleted.
