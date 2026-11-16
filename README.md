# Pocket Editing Instrument: Phases 0–2

`CLAUDE.md` is the source of truth. This build covers **Phase 0** (an app shell, design tokens and basic components), the **smallest working slice of Phase 1** (Photos/Files import, a reorderable clip sequence, whole-sequence playback, Trim with a filmstrip, in/out trimming, undo/redo, persistence, 9:16 H.264 export) and **Phase 2**: reference music, its waveform under the sequence, sync offset, loop region, clip/music levels and a silent-by-default export with a music sync note for Instagram.

The state CLAUDE.md calls **Explore** is labelled **Trim** in the app (the code still calls it `explore`).

The UI is deliberately plain. It is meant for functional testing, and the final photographic-instrument look comes later (see `DesignReferences/`, which is art direction only).

> **Build status (2026-11-16):** builds with Xcode 26.3 with no Swift warnings; swift-format lint is clean; 31 EditCore tests, 6 media-pipeline tests and 1 UI tour pass in the iPhone 17 Pro and iPhone 16e simulators. It has **not** been tested on a physical iPhone yet; see the device checklist below.

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
Media-pipeline tests (real AVFoundation exports of the demo clips + click track) and a UI tour that screenshots each state run in the Simulator:
```bash
xcodebuild test -project PocketInstrument.xcodeproj -scheme PocketInstrument \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Lint
Style rules live in `.swift-format` (4-space indent, 120 columns). Every app build runs a swift-format lint step that reports issues as Xcode warnings without failing the build. To lint or auto-fix from the terminal:
```bash
xcrun swift-format lint -r PocketInstrument PocketInstrumentTests PocketInstrumentUITests Packages
xcrun swift-format format -i -r PocketInstrument PocketInstrumentTests PocketInstrumentUITests Packages
```
`PocketInstrument.xcodeproj` is generated from `project.yml`. After editing `project.yml`, run `xcodegen generate` again.

## Architecture
```
Packages/EditCore/            Pure Swift with no AVFoundation, unit-tested
  MediaTime.swift             rational time (value/timescale), exact across timescales
  Model.swift                 SourceAsset, TimelineClip, AudioTrack, AutomationPoint,
                              LoopRange, SoundPolicy, ExportSettings, Project (versioned schema)
  SequenceMap.swift           source ↔ clip-local ↔ composition ↔ audio-reference time
  Audio.swift                 MusicPlacement, offset clamp, Loop In/Out rules, export sound
                              policy default, MusicSyncNote (sidecar), Waveform + cache format
  Commands.swift              EditingCommand protocol + Add/Move/Remove/Duplicate/Trim/…
  UndoStack.swift             snapshot undo/redo
  ProjectStore.swift          JSON project folders, atomic saves, media adoption
PocketInstrument/
  App/                        @main
  Design/                     Theme tokens, InstrumentButtonStyle, TimecodeText, GlassChip, LED, Haptics
  Media/                      CompositionBuilder (shared by preview and export), PlaybackEngine,
                              MediaImporter, ThumbnailCache, ExportService, WaveformAnalyzer,
                              DemoMediaGenerator (demo clips + 120 BPM click track)
  Library/                    Project library: create, open, rename, delete
  Workspace/                  WorkspaceModel + one workspace with Arrange / Trim / Mix decks,
                              SequenceLane (clips, waveform, cuts, loop bracket), ExportSheet
PocketInstrumentTests/        app-hosted media-pipeline tests (export audio, offsets, looping)
PocketInstrumentUITests/      tours the four states and attaches screenshots
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
| Trim: whole-source filmstrip, drag to scrub, ±1 frame, In/Out keys, draggable handles, loop in/out | Implemented |
| Undo / redo for every edit | Implemented |
| Autosave (debounced, and on backgrounding) and reopen with order, trims and framing intact | Implemented |
| Export 9:16 1080×1920 H.264 MP4 30 fps, silent option, progress, cancel, Save to Photos, Share | Implemented |
| Speed | Stored in the model and honoured by composition and export; no UI yet (Phase 4) |
| Reference music: one per project from Files (mp3, m4a, wav, aiff), a video's sound, or the **Demo click track** (30 s, 120 BPM, accented downbeat); replace/remove are undoable | Implemented |
| Waveform: AVAssetReader → mono PCM → Accelerate peaks off the main thread, cached in the project's `Cache/` | Implemented |
| Sequence lane under the tiles in Arrange and in Mix: clip segments, waveform in composition time, cut ticks, playhead, loop bracket | Implemented |
| Music under the Trim filmstrip (what plays under each source frame; slides with the In point) | Implemented |
| Sync: drag the waveform in Mix (one undo step), ±1 frame and ±10 ms nudges, m:ss.cc offset readout | Implemented |
| Loop region: tap the loop key to toggle; hold it for Loop In / Loop Out at the playhead, loop selected clip, loop all; drag the bracket handles (snap to cuts); persisted, undoable | Implemented |
| Clip and music faders (live while playing via AVAudioMix, one undo step per move) | Implemented |
| Release sound policy: Silent (default with music) · Clip audio only · Clip + music (private drafts); `<video>.sync.json` sidecar and "In Instagram, start the song at m:ss.cc" with Copy | Implemented |
| Volume automation, dial, motion | Not started (later phases, by design) |

## Device test checklist (please report back)
1. Create a project, add **Demo clips**, and play. Does the sequence play A → B → C and loop?
2. Check framing: B (portrait) should fill the frame, and A (landscape) should be cropped to its centre. Toggle **Fit** on A to see the letterbox.
3. Long-press a tile and drag to reorder. Then undo and redo.
4. **Trim** clip A: scrub, step frames, then drag the In/Out handles. The burned-in frame number shows exactly where you are. Press **In** and **Out** at the playhead, and turn on Loop.
5. Return to **Arrange**. Is the clip shorter, and does the sequence still play smoothly?
6. Import 3+ real videos from Photos, including a long one and an HEVC/HDR one. Note the import time.
7. Force-quit and relaunch, then reopen the project. Are the order and trims intact?
8. Export with clip audio on and then off. Save to Photos, check that the frames match the preview, and confirm the silent version is silent.
9. Use the app with VoiceOver for a minute. Can you select, explore and trim?

### Phase 2 checklist (Simulator is fine for 1–6)
1. New project → **Demo clips**. Go to **Mix** → **Click**. The waveform shows a tall click every 2 s (downbeats) and short ones between.
2. Arrange: the waveform lane sits under the tiles; cut ticks at 6 s and 11 s land on clicks. Play: each cut should fall on a click.
3. Trim clip A, move In to 0:00:08 (about half a beat). Back in Arrange the later cuts now sit between clicks; undo puts them back.
4. Mix: drag the waveform, then use ±1F / ±10MS. The readout changes; each drag or tap is one undo step.
5. Hold the loop key → **Loop In at playhead** at 0:02, then **Loop Out** at 0:04: a one-bar loop. Play; it should wrap on the downbeat. Tap the key to switch it off and on; undo.
6. Release: Silent is selected. Render, then Share/Save; the file has no sound. Render again with **Clip + music**: clicks are audible and on the cuts. Copy the sync line.
7. On device: import a real song from Files and a song from a video; check the sync note against Instagram's music picker.

## Preview vs export
- Preview always plays clips + music at the Mix levels. The Release sound policy only changes the exported file.
- A Silent export has no audio track at all, not a silent one. Clip audio only with clips that have no sound is also trackless.
- Music is trimmed to the sequence. It never plays before the first frame or after the last.
- Dragging the waveform snaps the offset to whole frames at the export rate; the ±10 ms buttons go finer. Preview and export place the music identically (same `CompositionBuilder`); the pipeline test measures exported clicks within 12 ms of their expected time.
- The sidecar `.sync.json` is written next to the video in the app's `Exports/` folder and offered via **Share sync file**; Save to Photos only saves the video.

## Known gaps / risks to watch
- **Not yet tested on a physical iPhone.** Photos import, HDR footage, touch feel and export quality need a real device.
- Export uses `AVAssetExportSession.exportAsynchronously`, which is deprecated on iOS 18 but works. It should move to `export(to:as:)` in Phase 5.
- Rebuilding the composition after an edit briefly reloads the player. This is fine for Phase 1, and smoothing it is a later optimisation.
- HDR sources are exported as SDR H.264 by the HighestQuality preset, so colours may shift. This needs checking on device.
- The sequence lane always shows the whole sequence; long sequences make the waveform and loop handles dense. Zoom comes later.
- Pinch-to-zoom in the filmstrip isn't implemented yet. For long clips, precise trimming relies on frame-step and the In/Out keys.
- Deleting a clip keeps its media file, so undo still works. Unused media is only removed when the whole project is deleted.
