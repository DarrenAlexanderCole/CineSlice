import AVFoundation
import EditCore
import Observation
import PhotosUI
import SwiftUI

/// UI state for one open project. All mutations of `project` go through
/// `perform(_:)` (undoable commands); media work happens in CompositionBuilder,
/// MediaImporter and ExportService, never in views.
@MainActor
@Observable
final class WorkspaceModel {
    enum Mode: String, CaseIterable {
        case arrange, explore, mix

        /// User-facing name. The explore state is shown as "Trim".
        var title: String {
            switch self {
            case .arrange: "Arrange"
            case .explore: "Trim"
            case .mix: "Mix"
            }
        }
    }

    private(set) var project: Project
    private(set) var mode: Mode = .arrange
    var selectedClipID: UUID? {
        // The CLIP fader resets on a new clip without a release, so a trim in progress ends here.
        didSet { if curveTrim?.target == .clipAudio { curveTrim = nil } }
    }
    /// Explore only: loops the clip's in/out range. Arrange and Mix use the project's loop region.
    var loopSelection = false { didSet { updateLoopRange() } }

    /// Peaks for the reference music, loaded from cache or analyzed in the background.
    private(set) var waveform: Waveform?

    /// In-progress trim while a handle is being dragged (committed on release as one undo step).
    var draftRange: MediaTimeRange?

    /// How far the sequence lane is magnified (1 = whole sequence). Zoomed, it follows the playhead.
    var laneZoom: Double = 1
    /// Explore: the filmstrip shows just around the clip's In–Out instead of the whole source.
    var trimZoom = false

    var importStatus: String?
    var alertMessage: String?
    private(set) var isRebuilding = false

    let engine = PlaybackEngine()
    let store: ProjectStore

    @ObservationIgnored private var undoStack = UndoStack()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    /// Audio track IDs in the loaded sequence item, for live level changes.
    @ObservationIgnored private var loadedTrackIDs: (clip: CMPersistentTrackID?, music: CMPersistentTrackID?)
    private(set) var undoName: String?
    private(set) var redoName: String?

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
        self.selectedClipID = project.clips.first?.id
    }

    // MARK: Derived

    var sequenceMap: SequenceMap { SequenceMap(project: project) }
    var selectedClip: TimelineClip? { selectedClipID.flatMap { project.clip(id: $0) } }
    var selectedSource: SourceAsset? { selectedClip.flatMap { project.source(for: $0) } }

    func mediaURL(for source: SourceAsset) -> URL? {
        store.isMissing(source, projectID: project.id) ? nil : store.mediaURL(for: source, projectID: project.id)
    }

    func mediaURL(for clip: TimelineClip) -> URL? {
        project.source(for: clip).flatMap { mediaURL(for: $0) }
    }

    /// Current time in the active domain: composition time in Arrange, source time in Explore.
    var currentTime: MediaTime { MediaTime(engine.currentTime) }

    /// The clip under the playhead in Arrange.
    var clipUnderPlayhead: UUID? { sequenceMap.entry(at: currentTime)?.clipID }

    var musicURL: URL? { project.referenceAudio.flatMap { store.audioURL(for: $0, projectID: project.id) } }

    /// One frame at the export rate: the nudge step for music and loop edges.
    var sequenceFrame: MediaTime { MediaTime(value: 1, timescale: Int32(project.exportSettings.frameRate)) }

    /// The fine music nudge.
    static let tenMilliseconds = MediaTime(value: 10, timescale: 1000)

    // MARK: Lifecycle

    func open() {
        rebuildSequence(keepingTime: .zero)
        loadWaveform()
    }

    func close() {
        saveNow()
        engine.tearDown()
        rebuildTask?.cancel()
        waveformTask?.cancel()
    }

    // MARK: Commands / undo

    func perform(_ command: EditingCommand) {
        let previous = project
        do {
            try undoStack.perform(command, on: &project)
            didEdit(from: previous)
        } catch {
            alertMessage = "\(command.actionName) failed: \(error.localizedDescription)"
            Haptics.warning()
        }
    }

    func undo() {
        let previous = project
        guard undoStack.undo(&project) != nil else { return }
        didEdit(from: previous)
    }

    func redo() {
        let previous = project
        guard undoStack.redo(&project) != nil else { return }
        didEdit(from: previous)
    }

    private func didEdit(from previous: Project) {
        undoName = undoStack.undoActionName
        redoName = undoStack.redoActionName
        if let id = selectedClipID, project.clip(id: id) == nil {
            selectedClipID = project.clips.first?.id
        }
        if mode == .explore, selectedClip == nil { mode = .arrange }
        if previous.referenceAudio?.fileName != project.referenceAudio?.fileName { loadWaveform() }
        scheduleSave()
        if mode != .explore, Self.playbackShape(previous) == Self.playbackShape(project) {
            // Levels or loop only: adjust the live item instead of reloading it, so playback doesn't stutter.
            applyLevels()
            updateLoopRange()
        } else {
            refreshPlayback()
        }
    }

    /// The parts of a project that need the composition rebuilt when they change.
    private static func playbackShape(_ p: Project) -> Project {
        var shape = p
        shape.modifiedAt = .distantPast
        shape.name = ""
        for i in shape.clips.indices {
            shape.clips[i].volume = 1
            shape.clips[i].levelCurve = AutomationLane()
        }
        shape.referenceAudio?.volume = 1
        shape.automation = Automation()
        shape.loop = nil
        shape.exportSettings = .vertical1080  // preview always plays the full mix; the policy is export-only
        return shape
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do { try store.save(project) } catch { alertMessage = "Couldn't save: \(error.localizedDescription)" }
    }

    // MARK: Playback wiring

    private func refreshPlayback() {
        switch mode {
        case .arrange, .mix:
            rebuildSequence(keepingTime: currentTime)
        case .explore:
            // Source item stays loaded; only the loop window may change.
            updateLoopRange()
        }
    }

    /// Rebuilds the sequence composition (debounced so rapid edits don't thrash the player).
    func rebuildSequence(keepingTime time: MediaTime, resume: Bool? = nil) {
        rebuildTask?.cancel()
        let snapshot = project
        let store = self.store
        isRebuilding = true
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            if snapshot.clips.isEmpty {
                self.engine.load(nil, duration: .zero, at: .zero)
                self.isRebuilding = false
                return
            }
            do {
                // Preview always plays clips + music at the mix levels; the sound policy applies to export only.
                let built = try await CompositionBuilder.build(
                    project: snapshot,
                    renderSize: CGSize(width: snapshot.exportSettings.width, height: snapshot.exportSettings.height),
                    frameRate: Int32(snapshot.exportSettings.frameRate),
                    includeClipAudio: true,
                    includeMusic: true,
                    mediaURL: {
                        store.isMissing($0, projectID: snapshot.id)
                            ? nil : store.mediaURL(for: $0, projectID: snapshot.id)
                    },
                    musicURL: snapshot.referenceAudio.flatMap { store.audioURL(for: $0, projectID: snapshot.id) })
                guard !Task.isCancelled, self.mode != .explore else { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                self.loadedTrackIDs = (built.clipAudioTrackID, built.musicTrackID)
                let target = CMTimeMinimum(time.cmTime, built.duration)
                self.engine.load(item, duration: built.duration, at: target, resume: resume)
                self.updateLoopRange()
            } catch {
                if !Task.isCancelled { self.alertMessage = error.localizedDescription }
            }
            self.isRebuilding = false
        }
    }

    private func updateLoopRange() {
        switch mode {
        case .arrange, .mix:
            engine.loopRange = activeLoop?.range.cmTimeRange
        case .explore:
            guard loopSelection, let clip = selectedClip else {
                engine.loopRange = nil
                return
            }
            engine.loopRange = (draftRange ?? clip.sourceRange).cmTimeRange
        }
    }

    /// Sets the player's levels; `clip` (for the selected clip) and `music` override the project's
    /// for live fader previews. A fader being recorded is always heard as it is.
    func applyLevels(clip: Float? = nil, music: Float? = nil) {
        guard mode != .explore, let item = engine.player.currentItem else { return }
        item.audioMix = CompositionBuilder.audioMix(
            project: mixProject, clipAudioTrackID: loadedTrackIDs.clip, musicTrackID: loadedTrackIDs.music,
            clipLevel: clip.flatMap { level in selectedClipID.map { (id: $0, volume: level) } }, musicLevel: music,
            writing: recording.map { ($0.target, recordLevel) })
    }

    // MARK: Selection & modes

    func select(_ clipID: UUID) {
        selectedClipID = clipID
        Haptics.detent()
        if mode != .explore, let start = sequenceMap.compositionStart(of: clipID) {
            engine.seek(to: start.cmTime, precise: true)
        }
        updateLoopRange()
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        Haptics.detent()
        switch newMode {
        case .explore:
            enterExplore()
        case .arrange, .mix:
            let fromExplore = mode == .explore
            mode = newMode
            draftRange = nil
            if fromExplore {
                let start = selectedClipID.flatMap { sequenceMap.compositionStart(of: $0) } ?? .zero
                rebuildSequence(keepingTime: start, resume: false)
            } else {
                updateLoopRange()
            }
        }
    }

    func enterExplore(_ clipID: UUID? = nil) {
        if let clipID { selectedClipID = clipID }
        guard let clip = selectedClip, let source = project.source(for: clip) else { return }
        guard let url = mediaURL(for: source) else {
            alertMessage = "This clip's media file is missing."
            return
        }
        rebuildTask?.cancel()
        mode = .explore
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        engine.load(item, duration: source.duration.cmTime, at: clip.sourceRange.start.cmTime, resume: false)
        updateLoopRange()
    }

    // MARK: Loop region (composition time)

    /// The loop region fitted to the current sequence, if it's switched on.
    var activeLoop: LoopRange? {
        guard let loop = project.loop, loop.isEnabled else { return nil }
        return loop.clamped(toSequence: project.duration)
    }

    /// Switches the loop on or off. The first time, it starts as the selected clip (or the whole sequence).
    func toggleLoop() {
        if var loop = project.loop {
            loop.isEnabled.toggle()
            perform(SetLoopCommand(loop: loop))
        } else {
            let range =
                selectedClipID.flatMap { sequenceMap.entry(for: $0)?.compositionRange }
                ?? MediaTimeRange(start: .zero, duration: project.duration)
            perform(SetLoopCommand(loop: LoopRange(range: range)))
        }
        Haptics.tap()
    }

    func setLoopRange(_ range: MediaTimeRange) {
        perform(SetLoopCommand(loop: LoopRange(range: range, isEnabled: true)))
    }

    /// Loops the selected clip's place in the sequence.
    func loopSelectedClip() {
        guard let id = selectedClipID, let range = sequenceMap.entry(for: id)?.compositionRange else { return }
        setLoopRange(range)
        Haptics.tap()
    }

    func loopWholeSequence() {
        setLoopRange(MediaTimeRange(start: .zero, duration: project.duration))
        Haptics.tap()
    }

    /// Loop In / Loop Out at the playhead, keeping the other edge when it still makes sense.
    func setLoopIn() {
        guard let loop = LoopRange.settingStart(currentTime, of: activeLoop, sequenceDuration: project.duration)
        else { return }
        perform(SetLoopCommand(loop: loop))
        Haptics.press()
    }

    func setLoopOut() {
        guard let loop = LoopRange.settingEnd(currentTime, of: activeLoop, sequenceDuration: project.duration)
        else { return }
        perform(SetLoopCommand(loop: loop))
        Haptics.press()
    }

    // MARK: Arrange edits

    func addSources(_ sources: [SourceAsset]) {
        guard !sources.isEmpty else { return }
        let command = AddClipsCommand(sources: sources)
        perform(command)
        selectedClipID = command.clipIDs.first
    }

    func move(_ clipID: UUID, to index: Int) { perform(MoveClipCommand(clipID: clipID, toIndex: index)) }
    func remove(_ clipID: UUID) { perform(RemoveClipCommand(clipID: clipID)) }
    func duplicate(_ clipID: UUID) {
        let command = DuplicateClipCommand(clipID: clipID)
        perform(command)
        selectedClipID = command.newClipID
    }
    func toggleFraming(_ clipID: UUID) {
        guard let clip = project.clip(id: clipID) else { return }
        perform(SetFramingCommand(clipID: clipID, framing: clip.framing == .fill ? .fit : .fill))
    }
    func rename(_ name: String) { perform(RenameProjectCommand(name: name)) }
    func setSoundPolicy(_ policy: SoundPolicy) {
        var settings = project.exportSettings
        settings.soundPolicy = policy
        perform(SetExportSettingsCommand(settings: settings))
    }

    // MARK: Mix edits

    func setClipVolume(_ volume: Float) {
        guard let id = selectedClipID else { return }
        perform(SetClipVolumeCommand(clipID: id, volume: volume))
    }
    func setMusicVolume(_ volume: Float) { perform(SetMusicVolumeCommand(volume: volume)) }

    // MARK: Automation recording

    /// A pass being recorded: the fader's level sampled against composition time.
    struct Pass {
        let target: AutomationTarget
        var samples: [AutomationPoint]
    }

    /// Write mode: touching a fader while the sequence plays in Mix records it into that curve.
    var isWriting = false {
        didSet { if !isWriting { finishPass() } }
    }
    /// The pass in progress, drawn live in the lane.
    private(set) var recording: Pass?

    /// A fader dragged (Write off) while the playhead is inside a recorded pass moves that whole
    /// pass by `delta`, heard and drawn live, and committed on release as one undo step.
    struct CurveTrim {
        let target: AutomationTarget
        let clipID: UUID?
        /// The pass's key, in its curve's own time (see `TrimAutomationCommand`).
        let time: MediaTime
        /// The curve's level under the playhead when the drag began.
        let start: Float
        var delta: Float = 0

        var command: TrimAutomationCommand {
            TrimAutomationCommand(target: target, clipID: clipID, time: time, delta: delta)
        }
    }
    private(set) var curveTrim: CurveTrim?

    /// The project as heard and drawn right now: with a curve trim in progress applied.
    var mixProject: Project {
        guard let curveTrim, curveTrim.delta != 0 else { return project }
        var trimmed = project
        try? curveTrim.command.apply(to: &trimmed)
        return trimmed
    }
    @ObservationIgnored private var recordLevel: Float = 0
    @ObservationIgnored private var recordTask: Task<Void, Never>?

    /// How often a held fader is sampled while recording.
    private static let recordInterval = Duration.milliseconds(33)

    /// What a fader shows: its level while recorded, the curve where the playhead is inside a
    /// recorded pass, otherwise the static level (the selected clip's, or the music's). The CLIP
    /// fader only follows a curve while the playhead is in the selected clip.
    func faderLevel(_ target: AutomationTarget) -> Float {
        if let recording, recording.target == target { return recordLevel }
        if let recorded = curveLevel(target) { return recorded }
        switch target {
        case .clipAudio: return selectedClip?.volume ?? 1
        case .music: return project.referenceAudio?.volume ?? 1
        }
    }

    /// True when the fader is following (or writing) a curve at the playhead.
    func isAutomated(_ target: AutomationTarget) -> Bool {
        recording?.target == target || curveLevel(target) != nil
    }

    private func curveLevel(_ target: AutomationTarget) -> Float? {
        if target == .clipAudio, clipUnderPlayhead != selectedClipID { return nil }
        return project.lane(for: target).value(at: currentTime)
    }

    /// The clip a CLIP fader ride is writing onto right now: the one under the playhead.
    var recordingClipID: UUID? { recording?.target == .clipAudio ? clipUnderPlayhead : nil }

    /// A fader moved (or was touched). Records when Write is on and the sequence is playing;
    /// inside a recorded pass, trims that pass; otherwise previews the static level.
    func faderMoved(_ target: AutomationTarget, to level: Float) {
        if let recording {
            guard recording.target == target else { return }
            recordLevel = level
            applyLevels()
        } else if isWriting, mode == .mix, engine.isPlaying {
            startPass(target, at: level)
        } else if curveTrim?.target == target || beginCurveTrim(target), let start = curveTrim?.start {
            curveTrim?.delta = level - start
            applyLevels()
        } else {
            switch target {
            case .clipAudio: applyLevels(clip: level)
            case .music: applyLevels(music: level)
            }
        }
    }

    /// A fader was let go at `level`. Returns true when that ended a recorded pass or a curve
    /// trim, so the static level is left alone.
    func faderReleased(_ target: AutomationTarget, at level: Float) -> Bool {
        if recording?.target == target {
            finishPass()
            return true
        }
        guard var trim = curveTrim, trim.target == target else { return false }
        curveTrim = nil
        trim.delta = level - trim.start
        if trim.delta != 0 { perform(trim.command) }
        applyLevels()
        return true
    }

    /// A fader set without a drag (VoiceOver adjust): trims the pass under the playhead, or sets the static level.
    func faderSet(_ target: AutomationTarget, to level: Float) {
        if let current = curveLevel(target), let pass = passKey(target) {
            perform(
                TrimAutomationCommand(
                    target: target, clipID: pass.clipID, time: pass.time, delta: level - current))
            return
        }
        switch target {
        case .clipAudio: setClipVolume(level)
        case .music: setMusicVolume(level)
        }
    }

    private func beginCurveTrim(_ target: AutomationTarget) -> Bool {
        guard let start = curveLevel(target), let pass = passKey(target) else { return false }
        curveTrim = CurveTrim(target: target, clipID: pass.clipID, time: pass.time, start: start)
        return true
    }

    /// The recorded pass under the playhead, named in its curve's own time.
    private func passKey(_ target: AutomationTarget) -> (clipID: UUID?, time: MediaTime)? {
        switch target {
        case .music:
            return (nil, currentTime)
        case .clipAudio:
            guard let hit = sequenceMap.sourceTime(atComposition: currentTime), hit.clipID == selectedClipID else {
                return nil
            }
            return (hit.clipID, hit.sourceTime)
        }
    }

    /// Clears the music curve, or one clip's curve (every clip's when `clipID` is nil).
    func clearAutomation(_ target: AutomationTarget, clipID: UUID? = nil) {
        perform(ClearAutomationCommand(target: target, clipID: clipID))
    }

    private func startPass(_ target: AutomationTarget, at level: Float) {
        recordLevel = level
        recording = Pass(target: target, samples: [AutomationPoint(time: currentTime, value: level)])
        applyLevels()
        Haptics.press()
        recordTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.recordInterval)
                guard let self, let pass = self.recording else { return }
                guard self.engine.isPlaying, self.mode == .mix else {
                    self.finishPass()
                    return
                }
                let now = self.currentTime
                if let last = pass.samples.last, now < last.time {
                    // The loop wrapped: keep what was recorded and carry on from the loop start.
                    self.commitPass()
                    self.recording = Pass(
                        target: pass.target, samples: [AutomationPoint(time: now, value: self.recordLevel)])
                    self.applyLevels()
                } else {
                    self.recording?.samples.append(AutomationPoint(time: now, value: self.recordLevel))
                }
            }
        }
    }

    /// Ends the pass in progress, if any, and writes it as one undo step.
    private func finishPass() {
        guard let pass = recording else { return }
        recordTask?.cancel()
        recordTask = nil
        if let last = pass.samples.last, currentTime >= last.time {
            recording?.samples.append(AutomationPoint(time: currentTime, value: recordLevel))
        }
        commitPass()
        applyLevels()
        Haptics.detent()
    }

    private func commitPass() {
        guard let pass = recording else { return }
        recording = nil
        // A touch too short to span two moments records nothing.
        guard AutomationSegment(recorded: pass.samples, sequenceDuration: project.duration) != nil else { return }
        perform(WriteAutomationCommand(target: pass.target, samples: pass.samples))
    }
    /// Moves the music; a locked song stays put (with a warning tap rather than an alert).
    func setMusicOffset(_ offset: MediaTime) {
        guard let music = project.referenceAudio else { return }
        guard !music.isLocked else {
            Haptics.warning()
            return
        }
        perform(SetMusicOffsetCommand(offset: offset))
    }

    /// Slides the music later (positive) or earlier (negative) by `step`.
    func nudgeMusic(by step: MediaTime) {
        guard let music = project.referenceAudio, !music.isLocked else { return }
        setMusicOffset(music.offset + step)
        Haptics.detent()
    }

    var isMusicLocked: Bool { project.referenceAudio?.isLocked ?? false }

    func toggleMusicLock() {
        perform(SetMusicLockCommand(isLocked: !isMusicLocked))
        Haptics.detent()
    }

    func removeMusic() { perform(SetReferenceAudioCommand(track: nil)) }

    func importMusicFile(_ url: URL) async {
        importStatus = "Importing music…"
        do {
            finishMusicImport(try await MediaImporter.importAudioFile(url, store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    func importMusic(fromVideo item: PhotosPickerItem) async {
        importStatus = "Extracting sound…"
        do {
            finishMusicImport(try await MediaImporter.importAudio(fromVideo: item, store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    func addDemoClickTrack() async {
        importStatus = "Generating click track…"
        do {
            finishMusicImport(try await DemoMediaGenerator.makeClickTrack(store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    private func finishMusicImport(_ track: AudioTrack) {
        importStatus = nil
        perform(SetReferenceAudioCommand(track: track))
        Haptics.success()
    }

    private func finishMusicImport(_ error: Error) {
        importStatus = nil
        alertMessage = error.localizedDescription
        Haptics.warning()
    }

    private func loadWaveform() {
        waveformTask?.cancel()
        waveform = nil
        guard let track = project.referenceAudio, let url = musicURL else { return }
        let cacheURL = store.waveformCacheURL(for: track, projectID: project.id)
        waveformTask = Task { [weak self] in
            let result = try? await WaveformAnalyzer.waveform(for: url, cacheURL: cacheURL)
            guard !Task.isCancelled, let self, self.project.referenceAudio?.fileName == track.fileName else { return }
            self.waveform = result
        }
    }

    // MARK: Explore edits (source time)

    func markIn() {
        guard let clip = selectedClip else { return }
        let t = currentTime
        perform(
            TrimClipCommand(
                clipID: clip.id,
                sourceRange: MediaTimeRange(start: t, end: max(clip.sourceRange.end, t + minimumClipDuration))))
        Haptics.press()
    }

    func markOut() {
        guard let clip = selectedClip else { return }
        let t = currentTime
        perform(
            TrimClipCommand(
                clipID: clip.id,
                sourceRange: MediaTimeRange(start: min(clip.sourceRange.start, t - minimumClipDuration), end: t)))
        Haptics.press()
    }

    func updateDraft(_ range: MediaTimeRange, previewAt time: MediaTime) {
        guard let source = selectedSource else { return }
        draftRange = TrimClipCommand.clamp(range, toSourceDuration: source.duration)
        engine.seek(to: time.cmTime, precise: false)
        updateLoopRange()
    }

    func commitDraft() {
        guard let clip = selectedClip, let range = draftRange else { return }
        draftRange = nil
        perform(TrimClipCommand(clipID: clip.id, sourceRange: range))
    }

    func scrub(to time: MediaTime, precise: Bool) {
        engine.seek(to: time.cmTime, precise: precise)
    }

    func step(_ frames: Int) {
        engine.step(frames: frames)
        Haptics.detent()
    }

    // MARK: Import

    func importPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        let (sources, errors) = await MediaImporter.importPhotos(items, store: store, projectID: project.id) {
            [weak self] i, n in
            self?.importStatus = "Importing \(i) of \(n)…"
        }
        finishImport(sources, errors)
    }

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        let (sources, errors) = await MediaImporter.importFiles(urls, store: store, projectID: project.id) {
            [weak self] i, n in
            self?.importStatus = "Importing \(i) of \(n)…"
        }
        finishImport(sources, errors)
    }

    func addDemoClips() async {
        importStatus = "Generating demo clips…"
        do {
            let sources = try await DemoMediaGenerator.makeDemoSources(store: store, projectID: project.id)
            finishImport(sources, [])
        } catch {
            finishImport([], [error])
        }
    }

    private func finishImport(_ sources: [SourceAsset], _ errors: [Error]) {
        importStatus = nil
        addSources(sources)
        if !errors.isEmpty {
            alertMessage = errors.map { $0.localizedDescription }.joined(separator: "\n")
        } else if !sources.isEmpty {
            Haptics.success()
        }
    }
}
