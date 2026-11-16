# Pocket Editing Instrument — Claude Code Project Instructions

## Mission
Build a native, portrait-first iPhone audiovisual editing instrument. The image is the artwork; the interface is the instrument. This is NOT a conventional multifeatured mobile NLE or a CapCut clone.

The core creative loop is **Arrange → Watch → Explore → Refine → Mix → Loop → Export**, with free movement among activities, not a mandatory wizard. Users should discover compelling moments in existing footage and shape relationships between image and sound. Editing should be fast, tactile, exploratory, non-destructive, and enjoyable.

## Approved product decisions
- Platform: native iOS, iPhone, portrait-first UI. Default composition/export 9:16; accept landscape, square and portrait sources with user-controlled framing.
- No external controllers. Use touch, haptics, and optionally Core Motion for experimental interactions. Do NOT assume arbitrary use of iPhone volume buttons or Camera Control for editing. Action Button shortcuts only where permitted.
- One elastic editing workspace with four contextual states: **Arrange, Explore, Mix, Release**. Keep preview, sequence, and transport consistent across states.
- Photographic preview is dominant. Physical-feeling touchscreen controls, smoked-glass overlays, restrained HUD markers, industrial precision. Avoid overly dense toolbars.
- Local-first. Non-destructive editing, no cloud dependency, no AI requirement for v1.
- Video preview should loop whole composition or a selected range. Playback continues during suitable edits when technically feasible.
- Music-reference workflow: import user-provided audio; never retrieve Instagram's protected music library. Offer silent export for later music attachment in Instagram, with synchronization metadata and caveat that precise in-app Instagram music offset cannot be guaranteed.

## Approved visual design
Colors: Obsidian `#151816`; Instrument `#30372F`; Olive `#56623B`; Signal `#D0DB65`; Aluminum `#BFC1B4`; Ivory `#ECE9DD`.
Typography: legible sans-serif, monospaced timecodes and small technical labels.
Materials: graphite, muted olive, brushed aluminum, smoked glass, restrained signal illumination. Video itself supplies most of the color.
Components: video preview with optional subtle overlay, clip tiles, expandable filmstrip, tactile transport buttons, in/out handles, waveform lane, loop bracket, one contextual virtual dial, fader, automation curve, context dock.
Interaction cues: pressed depth, active illumination, haptic detents, smooth elastic expansion. Respect Reduce Motion and VoiceOver. Functional controls must be native/drawn interactive UI, NOT static mockup images.
The reference visuals are ART DIRECTION, not pixel-perfect screenshots or permission to consume most of the phone with ornamental hardware. Favor usable tap targets and screen space.

## Four contextual states
1. Arrange: import multiple videos; see the whole sequence; drag to reorder; play whole composition; select clip.
2. Explore: selected clip expands into detailed filmstrip; shuttle, scrub, frame step; mark moments; adjust in/out; preview in context.
3. Mix: show audio waveform and volume control; user can perform volume changes during playback; record changes as automation, edit envelope statically. Distinguish clip audio and soundtrack levels.
4. Release: loop/review composition, choose export (9:16 H.264 first), choose sound policy (including silent), save/share finished file; preserve reference-music sync information.
These are states of one workspace, not four independent screens or onboarding steps.

## Recommended technology
- SwiftUI for native interface and state-driven components.
- AVFoundation / AVPlayer / AVMutableComposition and AVVideoComposition as appropriate for playback, editing, export; choose current supported APIs and handle SDK deprecations.
- CoreMedia CMTime for frame-relevant timestamps; avoid floating-point seconds as canonical edit storage.
- PhotosUI and file importer for user media; security-scoped access / managed local copies as needed.
- SwiftData or a robust local project document model with versioned schema.
- Core Haptics for tactile feedback, gracefully degrade.
- Core Motion for OPTIONAL, explicitly activated tilt experiments, not MVP dependency.
- Waveform analysis/cache with Accelerate or AVFoundation when audio phase begins.
- Keep preview, project model, and export composition generation separate.
- Test variable-frame-rate source handling, orientation, aspect-fit/fill and crop, mixed media sizes, audio/video timebases, interruption/recovery, missing assets, and export cancellation.

## Gesture principles
Tap clip selects; drag clip reorders in Arrange; tap or expand clip enters Explore; drag filmstrip scrubs; trim handles adjust source in/out; pinch zooms timeline; play/pause and loop have dedicated visible buttons. Avoid conflicts between drag-to-reorder and drag-to-trim; use distinct handles or contextual states. Contextual dial uses forgiving linear dragging rather than requiring circular tracing. Use explicit activation for any tilt action; include calibration, smoothing, dead zones and cancel.

## Build phases — implement in order
### Phase 0: Working app shell and design system
Create an Xcode iOS project that compiles, with preview-driven design tokens, reusable components, accessible controls, sample project and local demo media placeholders. Provide simulator screenshots or preview instructions. Ensure portrait-first layouts adapt to compact iPhones.
### Phase 1: Real editing MVP (first milestone)
Import videos, display clip thumbnails, arrange/reorder, show playable whole-sequence preview, select clip, expand detailed filmstrip, scrub, set in/out, non-destructively persist project, undo/redo, export a playable 9:16 video. Keep playback and export output consistent.
### Phase 2: Music and looping
Import user-supplied reference audio, waveform, align with sequence, whole/region looping, music/original audio levels, silent export option.
### Phase 3: Live mix
Record timestamped volume fader movements during playback; interpolate automation, display editable envelope, apply to preview and final export; support undo/redo.
### Phase 4: Experimental tactile interaction
Add contextual dial, haptics, optional hold-to-activate motion controls, precision frame jog and speed exploration. Validate on real device before expanding scope.
### Phase 5: Refinement
Accessibility, performance, export presets, project recovery, test coverage, Instagram handoff metadata and visual polish.

## Engineering constraints
- Prioritize compiling, usable code over impressive-looking static prototypes.
- Never destructively edit original footage.
- Project should reopen with same clip order, trims, and sound settings.
- Separate `SourceAsset`, `TimelineClip` (source range, placement, speed), `AudioTrack`, `AutomationPoint`, `LoopRange`, `Project`, and `ExportSettings`.
- Define coordinate mapping clearly among source time, clip-local time, composition time and audio-reference time.
- Build an EditingCommand protocol/undo stack for state mutations.
- Do not promise true real-time export-quality compositing without testing. Document preview/export differences.
- Do not imply app can programmatically attach licensed Instagram songs.
- Use actual functionality for every interactive control; no dead decorative buttons.
- Keep scope small; postpone complex effects, color grading, AI auto-edit, extensive transitions and multitrack mastering.

## First instruction to Claude
Inspect the current directory. If empty, scaffold a new SwiftUI iPhone project. First produce a concise implementation plan, file tree, and list of Xcode/device requirements. Then implement **Phase 0 + the smallest working vertical slice of Phase 1**: app shell, a coherent Arrange/Explore workspace, Photos import, selectable clip sequence, playback, and basic non-destructive trimming. Build and test what can be tested in the available environment. State explicitly if Xcode/simulator is unavailable; never claim a build succeeded without running it. Stop and summarize what works, what is mocked, and the next step. Do not implement every phase at once.
