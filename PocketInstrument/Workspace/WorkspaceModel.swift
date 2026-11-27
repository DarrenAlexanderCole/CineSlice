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
        case arrange, explore, mix, audio

        /// User-facing name. The explore state is shown as "Trim".
        var title: String {
            switch self {
            case .arrange: "Arrange"
            case .explore: "Trim"
            case .mix: "Mix"
            case .audio: "Audio"
            }
        }
    }

    private(set) var project: Project
    private(set) var mode: Mode = .arrange
    var selectedClipID: UUID? {
        // The CLIP fader resets on a new clip without a release, so a trim in progress ends here.
        didSet {
            if curveTrim?.target == .clipAudio { curveTrim = nil }
            if curveEditTarget == .clipAudio {
                curveDraft = nil
                selectedCurvePoint = nil
            }
            cropDraft = nil
            if selectedClipID != nil { isMusicSelected = false }
        }
    }
    /// Explore only: loops the clip's in/out range. Arrange and Mix use the project's loop region.
    var loopSelection = false { didSet { updateLoopRange() } }

    /// Peaks for the reference music, loaded from cache or analyzed in the background.
    private(set) var waveform: Waveform?

    /// In-progress trim while a handle is being dragged (committed on release as one undo step).
    var draftRange: MediaTimeRange?

    /// How far the sequence lane is magnified (1 = whole sequence). Zoomed, it follows the playhead.
    var laneZoom: Double = 1 {
        didSet { if laneZoom <= 1 { laneFocus = nil } }
    }
    /// Zoomed by a pinch: the time at the centre of the lane, so what was under the fingers stays
    /// there. Nil follows the playhead (the zoom key, and whenever playback starts).
    var laneFocus: Double?
    /// Explore: the filmstrip shows just around the clip's In–Out instead of the whole source.
    var trimZoom = false

    var importStatus: String?
    var alertMessage: String?
    private(set) var isRebuilding = false

    let engine = PlaybackEngine()
    /// The master EQ the player hears: the project's, or a knob's while it's being turned.
    let equalizer = EQSettings()
    /// The master EQ's taps on the loaded item, kept for every later change to its levels.
    @ObservationIgnored private var equalizerTaps: MasterEQTaps?
    let store: ProjectStore

    @ObservationIgnored private var undoStack = UndoStack()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var waveformTask: Task<Void, Never>?
    /// Audio track IDs in the loaded sequence item, and the clips playing split sound, for live
    /// level changes.
    @ObservationIgnored private var loadedTrackIDs:
        (
            clip: CMPersistentTrackID?, music: CMPersistentTrackID?, sounds: [UUID: CMPersistentTrackID],
            voice: CMPersistentTrackID?, separated: Set<UUID>
        ) = (nil, nil, [:], nil, [])
    private(set) var undoName: String?
    private(set) var redoName: String?

    init(project: Project, store: ProjectStore) {
        self.project = project
        self.store = store
        self.selectedClipID = project.clips.first?.id
        equalizer.set(project.masterEQ)
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
        makeMissingVoiceAudio()
    }

    func close() {
        saveNow()
        engine.tearDown()
        rebuildTask?.cancel()
        waveformTask?.cancel()
        voiceTasks.values.forEach { $0.cancel() }
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
        selectedCurvePoint = nil
        guard undoStack.undo(&project) != nil else { return }
        didEdit(from: previous)
    }

    func redo() {
        let previous = project
        selectedCurvePoint = nil
        guard undoStack.redo(&project) != nil else { return }
        didEdit(from: previous)
    }

    private func didEdit(from previous: Project) {
        undoName = undoStack.undoActionName
        redoName = undoStack.redoActionName
        if let id = selectedClipID, project.clip(id: id) == nil {
            selectedClipID = project.clips.first?.id
        }
        if let id = selectedSoundID, project.sound(id: id) == nil { selectedSoundID = nil }
        if let id = selectedLayerClipID, project.layerClip(id: id) == nil { selectedLayerClipID = nil }
        if project.referenceAudio == nil { isMusicSelected = false }
        if mode == .explore, selectedClip == nil { mode = .arrange }
        if previous.referenceAudio?.fileName != project.referenceAudio?.fileName { loadWaveform() }
        scheduleSave()
        extendGuideIfNeeded()
        makeMissingVoiceAudio()
        equalizer.set(project.masterEQ)
        if selectedClip == nil { isCropping = false }
        if mode != .explore, Self.playbackShape(previewed(previous)) == Self.playbackShape(previewed(project)) {
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
            // Split or not changes the tracks; the voice and scene levels are only levels.
            if shape.clips[i].balance != nil { shape.clips[i].balance = .init(voice: 1, scene: 1) }
        }
        shape.referenceAudio?.volume = 1
        for t in shape.soundTracks.indices {
            shape.soundTracks[t].isMuted = false
            for c in shape.soundTracks[t].clips.indices {
                shape.soundTracks[t].clips[c].volume = 1
                shape.soundTracks[t].clips[c].fadeIn = .zero
                shape.soundTracks[t].clips[c].fadeOut = .zero
            }
        }
        shape.automation = Automation()
        shape.loop = nil
        // Only the frame and its rate reach the preview. It always plays the full mix (the sound
        // policy is export-only), shows the whole frame with the feed's cut marked, and plays the
        // 1080 sequence frame whatever the file's resolution, codec and bitrates.
        let frame = shape.exportSettings
        shape.exportSettings = ExportSettings(width: frame.width, height: frame.height, frameRate: frame.frameRate)
        shape.masterEQ = .flat  // heard through `equalizer`, which follows it without a reload
        return shape
    }

    /// What the preview plays: while cropping, the selected clip shows its whole frame, so its
    /// crop can be drawn over it and moved.
    private func previewed(_ p: Project) -> Project {
        guard isCropping, let id = selectedClipID, let i = p.index(ofClip: id) else { return p }
        var shown = p
        shown.clips[i].crop = nil
        return shown
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
        case .arrange, .mix, .audio:
            rebuildSequence(keepingTime: currentTime)
        case .explore:
            // Source item stays loaded; only the loop window may change.
            updateLoopRange()
        }
    }

    /// Rebuilds the sequence composition (debounced so rapid edits don't thrash the player).
    func rebuildSequence(keepingTime time: MediaTime, resume: Bool? = nil) {
        rebuildTask?.cancel()
        let snapshot = previewed(project)
        let store = self.store
        let taps = MasterEQTaps(equalizer)
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
                    musicURL: snapshot.referenceAudio.flatMap { store.audioURL(for: $0, projectID: snapshot.id) },
                    soundURL: { store.soundURL(for: $0, projectID: snapshot.id) },
                    clipStems: { store.stemURLs(for: $0, source: $1, projectID: snapshot.id) },
                    equalizer: taps)
                guard !Task.isCancelled, self.mode != .explore else { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                self.equalizerTaps = taps
                self.loadedTrackIDs = (
                    built.clipAudioTrackID, built.musicTrackID, built.soundTrackIDs, built.voiceTrackID,
                    built.separatedClipIDs
                )
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
        case .arrange, .mix, .audio:
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
    /// for live fader previews, as `balance` does the selected clip's voice and scene levels. A
    /// fader being recorded is always heard as it is. `sound` stands in for the sound of its id,
    /// for LIGHTBOX's level and fade faders; `clipFades` and `musicFades` stand in for the selected
    /// clip's and the song's fades.
    func applyLevels(
        clip: Float? = nil, music: Float? = nil, balance: SoundBalance? = nil, sound: SoundClip? = nil,
        clipFades: (in: MediaTime, out: MediaTime)? = nil, musicFades: (in: MediaTime, out: MediaTime)? = nil
    ) {
        equalizer.set(project.masterEQ)
        guard mode != .explore, let item = engine.player.currentItem else { return }
        var mixed = mixProject
        if let sound, let at = mixed.soundLocation(id: sound.id) {
            mixed.soundTracks[at.track].clips[at.index] = sound
        }
        if let clipFades, let id = selectedClipID, let i = mixed.index(ofClip: id) {
            mixed.clips[i].fadeIn = clipFades.in
            mixed.clips[i].fadeOut = clipFades.out
        }
        if let musicFades {
            mixed.referenceAudio?.fadeIn = musicFades.in
            mixed.referenceAudio?.fadeOut = musicFades.out
        }
        item.audioMix = CompositionBuilder.audioMix(
            project: mixed, clipAudioTrackID: loadedTrackIDs.clip, musicTrackID: loadedTrackIDs.music,
            soundTrackIDs: loadedTrackIDs.sounds, voiceTrackID: loadedTrackIDs.voice,
            separated: loadedTrackIDs.separated,
            clipLevel: clip.flatMap { level in selectedClipID.map { (id: $0, volume: level) } }, musicLevel: music,
            balance: balance.flatMap { b in selectedClipID.map { (id: $0, balance: b) } },
            writing: recording.map { ($0.target, recordLevel) },
            equalizer: equalizerTaps)
    }

    /// Plays the master EQ at `eq` while a knob is turned, without an undo step.
    func previewEQ(_ eq: MasterEQ) { equalizer.set(eq) }

    /// Sets the master EQ, as one undo step.
    func setMasterEQ(_ eq: MasterEQ) {
        guard eq != project.masterEQ else {
            equalizer.set(eq)
            return
        }
        perform(SetMasterEQCommand(eq: eq))
    }

    // MARK: Selection & modes

    func select(_ clipID: UUID) {
        let changed = clipID != selectedClipID
        selectedClipID = clipID
        Haptics.detent()
        if mode != .explore, let start = sequenceMap.compositionStart(of: clipID) {
            // Cropping, the newly selected clip is the one shown whole.
            if isCropping, changed {
                rebuildSequence(keepingTime: start)
            } else {
                engine.seek(to: start.cmTime, precise: true)
            }
        }
        updateLoopRange()
    }

    /// LIGHTBOX: selects a clip (or clears the selection) without moving the playhead, so the
    /// scissors can cut the selected clip where the playhead already is.
    func selectInPlace(_ clipID: UUID?) {
        guard clipID != selectedClipID || selectedSoundID != nil || selectedLayerClipID != nil || isMusicSelected
        else { return }
        selectedSoundID = nil
        selectedLayerClipID = nil
        isMusicSelected = false
        selectedClipID = clipID
        Haptics.detent()
    }

    // MARK: Sounds (LIGHTBOX)

    /// The sound selected on LIGHTBOX's sound lanes. Selecting one clears the clip selection.
    private(set) var selectedSoundID: UUID?

    func selectSound(_ id: UUID) {
        guard id != selectedSoundID else { return }
        selectedClipID = nil
        selectedLayerClipID = nil
        isMusicSelected = false
        selectedSoundID = id
        Haptics.detent()
    }

    func importSoundFile(_ url: URL) async {
        importStatus = "Importing sound…"
        do {
            binSound(try await MediaImporter.importAudioFile(url, store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    func importSound(fromVideo item: PhotosPickerItem) async {
        importStatus = "Extracting sound…"
        do {
            binSound(try await MediaImporter.importAudio(fromVideo: item, store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    func addDemoSound() async {
        importStatus = "Generating demo sound…"
        do {
            binSound(try await DemoMediaGenerator.makeDemoSound(store: store, projectID: project.id))
        } catch {
            finishMusicImport(error)
        }
    }

    /// A sound brought in goes to the bin, which opens to show it.
    private func binSound(_ file: AudioTrack, isTake: Bool = false) {
        importStatus = nil
        perform(AddToBinCommand(sounds: [Self.binSound(of: file, isTake: isTake)]))
        if !isTake {
            isBinOpen = true
            Haptics.success()
        }
    }

    private static func binSound(of file: AudioTrack, isTake: Bool) -> BinSound {
        BinSound(
            fileName: file.fileName, originalFilename: file.originalFilename, duration: file.duration, isTake: isTake)
    }

    /// A new sound starts at the playhead, on the first lane with room there.
    private func addSound(_ file: AudioTrack) {
        importStatus = nil
        let clip = SoundClip(
            fileName: file.fileName, originalFilename: file.originalFilename, fileDuration: file.duration,
            start: currentTime)
        perform(AddSoundCommand(clip: clip))
        if project.sound(id: clip.id) != nil {
            selectSound(clip.id)
            Haptics.success()
        }
    }

    /// Moves a sound to `start` on lane `track` (one past the last makes a new lane). False,
    /// with a warning tap, when another sound is in the way there.
    @discardableResult
    func moveSound(_ id: UUID, toTrack track: Int, start: MediaTime) -> Bool {
        let range = project.sound(id: id).map { MediaTimeRange(start: start, duration: $0.sourceRange.duration) }
        guard let range, project.soundFits(range, onTrack: track, excluding: id) else {
            Haptics.warning()
            return false
        }
        perform(MoveSoundCommand(clipID: id, track: track, start: start))
        return true
    }

    /// The selected sound, when the playhead is inside it far enough from its ends to cut there.
    var soundSplitTime: MediaTime? {
        guard let id = selectedSoundID, let sound = project.sound(id: id),
            SplitSoundCommand.canSplit(sound, at: currentTime)
        else { return nil }
        return currentTime
    }

    /// Cuts the selected sound at the playhead and selects its second half.
    func splitSelectedSound() {
        guard let id = selectedSoundID, let time = soundSplitTime else {
            Haptics.warning()
            return
        }
        let command = SplitSoundCommand(clipID: id, time: time)
        perform(command)
        selectedSoundID = command.newClipID
        Haptics.press()
    }

    var selectedSound: SoundClip? { selectedSoundID.flatMap { project.sound(id: $0) } }

    /// The selected sound's level, as one undo step.
    func setSoundLevel(_ volume: Float) {
        guard let sound = selectedSound, sound.volume != volume else { return applyLevels() }
        perform(SetSoundLevelCommand(clipID: sound.id, volume: volume))
    }

    /// The selected sound's fades, as one undo step.
    func setSoundFades(in fadeIn: MediaTime, out fadeOut: MediaTime) {
        guard let sound = selectedSound, sound.fadeIn != fadeIn || sound.fadeOut != fadeOut else {
            return applyLevels()
        }
        perform(SetSoundFadesCommand(clipID: sound.id, fadeIn: fadeIn, fadeOut: fadeOut))
    }

    /// Mutes or unmutes a sound lane.
    func toggleMute(soundTrack id: UUID) {
        guard let lane = project.soundTracks.first(where: { $0.id == id }) else { return }
        perform(SetSoundTrackMuteCommand(trackID: id, isMuted: !lane.isMuted))
        Haptics.detent()
    }

    // MARK: Stacked video lanes (LIGHTBOX)

    /// The clip selected on a video lane above the sequence. Selecting one clears the others.
    private(set) var selectedLayerClipID: UUID?
    var selectedLayerClip: LayerClip? { selectedLayerClipID.flatMap { project.layerClip(id: $0) } }

    func selectLayerClip(_ id: UUID) {
        guard id != selectedLayerClipID else { return }
        selectedClipID = nil
        selectedSoundID = nil
        isMusicSelected = false
        selectedLayerClipID = id
        Haptics.detent()
    }

    /// LIGHTBOX: the song is selected, for Volume and Fade. Selecting anything else clears it.
    private(set) var isMusicSelected = false

    func selectMusic() {
        guard !isMusicSelected, project.referenceAudio != nil else { return }
        selectedClipID = nil
        selectedSoundID = nil
        selectedLayerClipID = nil
        isMusicSelected = true
        Haptics.detent()
    }

    /// Whether LIGHTBOX is showing: there, clips and music brought in land at the playhead.
    var isInLightbox = false

    /// Whether the next imported clips go in at the playhead, on the lowest video lane with room
    /// (LIGHTBOX), rather than into the sequence at `importInsertIndex`.
    var importsAtPlayhead = false

    /// Moves a clip of the sequence or a stacked clip to `start` on video lane `lane` (0 for the
    /// sequence). False, with a warning tap, when something is in the way there.
    @discardableResult
    func moveVideoClip(_ id: UUID, toLane lane: Int, start: MediaTime) -> Bool {
        guard MoveVideoClipCommand.canMove(id, toLane: lane, start: start, in: project) else {
            Haptics.warning()
            return false
        }
        perform(MoveVideoClipCommand(clipID: id, lane: lane, start: start))
        return true
    }

    /// Slides the music to `offset` on audio lane `lane`. False, with a warning tap, when it's
    /// locked or a sound is in the way there.
    @discardableResult
    func placeMusic(lane: Int, offset: MediaTime) -> Bool {
        guard var music = project.referenceAudio, !music.isLocked else {
            Haptics.warning()
            return false
        }
        music.offset = music.clampedOffset(offset, sequenceDuration: project.duration)
        guard project.audioLaneFits(music.timelineRange, lane: lane, excludingMusic: true) else {
            Haptics.warning()
            return false
        }
        perform(PlaceMusicCommand(lane: lane, offset: offset))
        return true
    }

    /// The selected stacked clip, when the playhead is inside it far enough from its ends to cut.
    var layerSplitTime: MediaTime? {
        guard let clip = selectedLayerClip, SplitLayerClipCommand.canSplit(clip, at: currentTime) else { return nil }
        return currentTime
    }

    /// Cuts the selected stacked clip at the playhead and selects its second half.
    func splitSelectedLayerClip() {
        guard let id = selectedLayerClipID, let time = layerSplitTime else {
            Haptics.warning()
            return
        }
        let command = SplitLayerClipCommand(clipID: id, time: time)
        perform(command)
        selectedLayerClipID = command.newClipID
        Haptics.press()
    }

    /// What LIGHTBOX's Trim works on: the selected stacked clip, sound or clip of the sequence.
    var trimTarget: TrimTarget? {
        if let id = selectedLayerClipID { return .layerClip(id) }
        if let id = selectedSoundID { return .sound(id) }
        if let id = selectedClipID { return .clip(id) }
        return nil
    }

    /// Whether the selection can lose its start (or end) up to the playhead.
    func canTrimSelection(_ edge: TrimEdge) -> Bool {
        guard let target = trimTarget else { return false }
        return TrimAtCommand.canTrim(target, edge: edge, at: currentTime, in: project)
    }

    /// Trims the selection back to the playhead from one end. What's kept stays where it played.
    func trimSelection(_ edge: TrimEdge) {
        guard let target = trimTarget, canTrimSelection(edge) else {
            Haptics.warning()
            return
        }
        perform(TrimAtCommand(target: target, edge: edge, time: currentTime))
        Haptics.press()
    }

    /// Takes the selected sound or stacked clip off its lane, or the selected clip out of the
    /// sequence.
    func removeSelection() {
        if let id = selectedLayerClipID {
            perform(RemoveLayerClipCommand(clipID: id))
        } else if let id = selectedSoundID {
            perform(RemoveSoundCommand(clipID: id))
        } else if let id = selectedClipID {
            // The rest stay where they are, lined up with the lanes above and below.
            perform(RemoveClipCommand(clipID: id, leavesGap: true))
        } else {
            return
        }
        Haptics.press()
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        Haptics.detent()
        if newMode != .mix { curveEditTarget = nil }
        if newMode != .arrange { setCropping(false) }
        switch newMode {
        case .explore:
            enterExplore()
        case .arrange, .mix, .audio:
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

    /// Turning the phone sideways: LIGHTBOX works in composition time on the whole sequence. From
    /// Trim it goes back to the sequence at the same frame; crop editing and a write pass end.
    func enterLightbox() {
        if isCropping { setCropping(false) }
        isWriting = false
        guard mode == .explore else { return }
        let time = selectedClipID.flatMap { sequenceMap.compositionTime(clipID: $0, sourceTime: currentTime) } ?? .zero
        mode = .arrange
        draftRange = nil
        rebuildSequence(keepingTime: time, resume: false)
    }

    /// Clip starts and the sequence end, in composition time: where Previous and Next land.
    /// Clip starts, clip ends where a gap follows, and the sequence end, in composition time:
    /// where Previous and Next land.
    var cutTimes: [MediaTime] {
        let map = sequenceMap
        let edges = map.entries.flatMap { [$0.compositionRange.start, $0.compositionRange.end] } + [map.duration]
        return Array(Set(edges)).sorted()
    }

    /// The sequence index of the cut nearest the playhead (0 is the start, `clips.count` the end).
    var cutIndexNearPlayhead: Int {
        let now = currentTime.seconds
        let map = sequenceMap
        let cuts = (map.entries.map(\.compositionRange.start) + [map.duration]).map(\.seconds)
        return cuts.indices.min { abs(cuts[$0] - now) < abs(cuts[$1] - now) } ?? project.clips.count
    }

    /// Jumps the playhead to the previous or next cut. Back from just after a cut goes to the one before.
    func jumpToCut(forward: Bool) {
        let now = currentTime
        let nearly = MediaTime(value: 1, timescale: 10)
        // Half a frame: a cut the playhead is already on (to rounding) doesn't count as the next one.
        let halfFrame = sequenceFrame.scaled(by: 0.5)
        let target =
            forward
            ? cutTimes.first { $0 > now + halfFrame } : cutTimes.last { $0 < now - nearly } ?? .zero
        guard let target else { return }
        engine.seek(to: target.cmTime, precise: true)
        Haptics.detent()
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
        loadExploreItem(clip, source: source, url: url, at: clip.sourceRange.start.cmTime, resume: false)
    }

    /// Loads the selected clip's source for Explore, its sound split at the clip's levels when the
    /// split is made, so what Explore plays matches the sequence.
    private func loadExploreItem(_ clip: TimelineClip, source: SourceAsset, url: URL, at time: CMTime, resume: Bool?) {
        let stems = store.stemURLs(for: clip, source: source, projectID: project.id)
        guard stems != nil || clip.balance != nil || source.look != nil else {
            engine.load(
                AVPlayerItem(asset: AVURLAsset(url: url)), duration: source.duration.cmTime, at: time, resume: resume)
            updateLoopRange()
            return
        }
        let clipID = clip.id
        let balance = clip.balance
        let look = source.look
        rebuildTask = Task { [weak self] in
            let item = await CompositionBuilder.sourceItem(url: url, stems: stems, balance: balance)
            if let look {
                // The source through its look, like the sequence plays it.
                item.videoComposition = try? await AVVideoComposition.videoComposition(
                    with: item.asset,
                    applyingCIFiltersWithHandler: { request in
                        request.finish(with: LookLibrary.apply(look, to: request.sourceImage), context: nil)
                    })
            }
            guard let self, !Task.isCancelled, self.mode == .explore, self.selectedClipID == clipID else { return }
            self.engine.load(item, duration: source.duration.cmTime, at: time, resume: resume)
            self.updateLoopRange()
        }
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

    /// Where the next imported clips go in the sequence; nil appends them. LIGHTBOX sets it to the
    /// cut nearest the playhead as it opens a picker, so footage lands where the editing is.
    var importInsertIndex: Int?

    func addSources(_ sources: [SourceAsset]) {
        guard !sources.isEmpty else { return }
        if importsAtPlayhead {
            importsAtPlayhead = false
            importInsertIndex = nil
            let command = AddClipsAtCommand(sources: sources, start: currentTime)
            perform(command)
            guard let first = command.clipIDs.first, let lane = command.lane(in: project) else { return }
            if lane == 0 { selectInPlace(first) } else { selectLayerClip(first) }
            return
        }
        let command = AddClipsCommand(sources: sources, insertIndex: importInsertIndex)
        importInsertIndex = nil
        perform(command)
        selectedClipID = command.clipIDs.first
    }

    func move(_ clipID: UUID, to index: Int) { perform(MoveClipCommand(clipID: clipID, toIndex: index)) }
    /// LIGHTBOX's free move: the clip to `start`, the others staying put (see `PlaceClipCommand`).
    func place(_ clipID: UUID, at start: MediaTime) { perform(PlaceClipCommand(clipID: clipID, start: start)) }
    func remove(_ clipID: UUID) { perform(RemoveClipCommand(clipID: clipID)) }
    func duplicate(_ clipID: UUID) {
        let command = DuplicateClipCommand(clipID: clipID)
        perform(command)
        selectedClipID = command.newClipID
    }
    /// Where a split at the playhead would cut, in Arrange: the clip under it and the source time
    /// there. nil on a cut, or too near one to leave two halves.
    var splitPoint: (clipID: UUID, sourceTime: MediaTime)? {
        guard mode != .explore, let hit = sequenceMap.sourceTime(atComposition: currentTime),
            let clip = project.clip(id: hit.clipID), SplitClipCommand.canSplit(clip, at: hit.sourceTime)
        else { return nil }
        return hit
    }

    /// Cuts the clip under the playhead in two there, and selects the second half, which starts
    /// at the playhead. Playback carries on; nothing moves in the sequence.
    func splitAtPlayhead() {
        guard let point = splitPoint else {
            Haptics.warning()
            return
        }
        let command = SplitClipCommand(clipID: point.clipID, sourceTime: point.sourceTime)
        perform(command)
        selectedClipID = command.newClipID
        Haptics.press()
    }
    func toggleFraming(_ clipID: UUID) {
        guard let clip = project.clip(id: clipID) else { return }
        perform(SetFramingCommand(clipID: clipID, framing: clip.framing == .fill ? .fit : .fill))
    }
    func rename(_ name: String) { perform(RenameProjectCommand(name: name)) }

    // MARK: Crop

    /// Arrange: the selected clip's crop (its push-in) is being set. That clip then plays whole,
    /// with the crop drawn over it to move and size.
    private(set) var isCropping = false
    /// The crop while a finger is moving it, committed on release as one undo step.
    var cropDraft: Crop?

    /// The crop drawn over the picture while cropping.
    var shownCrop: Crop { cropDraft ?? selectedClip?.crop ?? .full }

    /// Starts or stops cropping the selected clip. Starting brings the playhead into that clip.
    func setCropping(_ on: Bool) {
        guard on != isCropping else { return }
        guard !on || (mode == .arrange && selectedClip != nil) else { return }
        isCropping = on
        cropDraft = nil
        var time = currentTime
        if on, let id = selectedClipID, clipUnderPlayhead != id, let start = sequenceMap.compositionStart(of: id) {
            time = start
        }
        rebuildSequence(keepingTime: time)
        Haptics.detent()
    }

    func commitCrop() {
        guard let id = selectedClipID, let draft = cropDraft else { return }
        cropDraft = nil
        guard draft != (selectedClip?.crop ?? .full) else { return }
        perform(SetCropCommand(clipID: id, crop: draft))
    }

    func resetCrop() {
        guard let id = selectedClipID, selectedClip?.crop != nil else { return }
        cropDraft = nil
        perform(SetCropCommand(clipID: id, crop: nil))
        Haptics.press()
    }
    func setFeedCut(_ on: Bool) {
        var settings = project.exportSettings
        settings.cutsToFeed = on
        perform(SetExportSettingsCommand(settings: settings))
    }
    /// Resolution, codec, bitrates, frame rate or a preset: one undo step each.
    func setExportSettings(_ settings: ExportSettings) {
        perform(SetExportSettingsCommand(settings: settings))
    }
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

    /// The selected clip's sound fades, as one undo step.
    func setClipFades(in fadeIn: MediaTime, out fadeOut: MediaTime) {
        guard let clip = selectedClip, clip.fadeIn != fadeIn || clip.fadeOut != fadeOut else {
            return applyLevels()
        }
        perform(SetClipFadesCommand(clipID: clip.id, fadeIn: fadeIn, fadeOut: fadeOut))
    }

    /// The song's fades, as one undo step.
    func setMusicFades(in fadeIn: MediaTime, out fadeOut: MediaTime) {
        guard let music = project.referenceAudio, music.fadeIn != fadeIn || music.fadeOut != fadeOut else {
            return applyLevels()
        }
        perform(SetMusicFadesCommand(fadeIn: fadeIn, fadeOut: fadeOut))
    }

    // MARK: Voice (Audio state)

    /// Sources whose sound is being split by `VoiceSeparator`, and how far along (0…1).
    private(set) var voiceProgress: [UUID: Double] = [:]
    @ObservationIgnored private var voiceTasks: [UUID: Task<Void, Never>] = [:]
    /// The split started last. Each waits for the one before, so only one model runs at a time:
    /// two at once can run the phone out of memory, and the app is killed with neither made.
    @ObservationIgnored private var lastVoiceTask: Task<Void, Never>?
    /// Sources that couldn't be processed this session, so edits don't retry (and alert) each time.
    @ObservationIgnored private var voiceFailures: Set<UUID> = []

    /// Export waits for this: until then, clips set to split would export silent.
    var isProcessingVoice: Bool { !voiceProgress.isEmpty }

    /// Plays the selected clip's sound as recorded (nil), or split into voices and scene at these
    /// levels. It applies at once; the clip is silent until its split is ready.
    func setSoundBalance(_ balance: SoundBalance?) {
        guard let clip = selectedClip, clip.balance != balance else { return }
        perform(SetSoundBalanceCommand(clipID: clip.id, balance: balance))
    }

    /// Splits the sound of every source a clip wants processed and that isn't on disk yet (new,
    /// or the cache was cleared). One pass makes both versions.
    private func makeMissingVoiceAudio() {
        for clip in project.clips {
            guard clip.balance != nil, let source = project.source(for: clip), source.hasAudio,
                voiceTasks[source.id] == nil, !voiceFailures.contains(source.id), let url = mediaURL(for: source),
                store.stemURLs(for: clip, source: source, projectID: project.id) == nil
            else { continue }
            let voiceURL = store.stemCacheURL(for: source, stem: .voice, projectID: project.id)
            let reducedURL = store.stemCacheURL(for: source, stem: .scene, projectID: project.id)
            let id = source.id
            voiceProgress[id] = 0
            let previous = lastVoiceTask
            let task = Task { [weak self] in
                await previous?.value
                do {
                    try Task.checkCancellation()
                    try await VoiceSeparator.separate(source: url, voiceURL: voiceURL, reducedURL: reducedURL) {
                        progress in
                        Task { @MainActor in
                            if self?.voiceProgress[id] != nil { self?.voiceProgress[id] = progress }
                        }
                    }
                } catch {
                    if !Task.isCancelled {
                        self?.voiceFailures.insert(id)
                        self?.alertMessage = "Couldn't process this clip's sound: \(error.localizedDescription)"
                    }
                }
                guard let self, !Task.isCancelled else { return }
                self.voiceTasks[id] = nil
                self.voiceProgress[id] = nil
                // The files don't change the project, so nothing else would reload playback.
                if self.mode != .explore {
                    self.rebuildSequence(keepingTime: self.currentTime)
                } else if let clip = self.selectedClip, let source = self.project.source(for: clip), source.id == id,
                    let media = self.mediaURL(for: source)
                {
                    self.loadExploreItem(clip, source: source, url: media, at: self.engine.currentTime, resume: nil)
                }
            }
            voiceTasks[id] = task
            lastVoiceTask = task
        }
    }

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

    /// The project as heard and drawn right now: with a curve trim or point drag in progress applied.
    var mixProject: Project {
        guard curveTrim.map({ $0.delta != 0 }) ?? false || curveDraft != nil else { return project }
        var drafted = project
        if let curveTrim, curveTrim.delta != 0 { try? curveTrim.command.apply(to: &drafted) }
        if let curveDraft { try? curveDraft.apply(to: &drafted) }
        return drafted
    }

    // MARK: Editing curve points

    /// Mix: the curve being edited by hand in the lane (the selected clip's for clip sound), or
    /// nil when the lane scrubs and slides as usual.
    var curveEditTarget: AutomationTarget? {
        didSet {
            curveDraft = nil
            selectedCurvePoint = nil
            if curveEditTarget != nil, engine.isPlaying { engine.pause() }
        }
    }
    /// A point being dragged or a stroke being drawn, heard and shown live; committed on
    /// release as one undo step.
    private(set) var curveDraft: (any EditingCommand)?
    /// The stroke being drawn, in composition time and in time order.
    @ObservationIgnored private var stroke: [AutomationPoint] = []
    @ObservationIgnored private var strokeLast: AutomationPoint?

    /// One stored point of the edited curve, placed in composition time.
    struct CurveHandle: Hashable {
        let segment: Int
        let point: Int
        let position: AutomationPoint
    }

    /// The edited curve's points where they play (with a drag in progress applied). A clip's
    /// points outside its In–Out don't play, so they aren't offered.
    var curveHandles: [CurveHandle] {
        guard let target = curveEditTarget else { return [] }
        let shown = mixProject
        switch target {
        case .music:
            return shown.automation.music.segments.enumerated().flatMap { s, segment in
                segment.points.enumerated().map { p, point in CurveHandle(segment: s, point: p, position: point) }
            }
        case .clipAudio:
            guard let id = selectedClipID, let clip = shown.clip(id: id) else { return [] }
            return clip.levelCurve.segments.enumerated().flatMap { s, segment in
                segment.points.enumerated().compactMap { p, point in
                    guard clip.sourceRange.contains(point.time) || point.time == clip.sourceRange.end,
                        let time = compositionTime(ofSource: point.time)
                    else { return nil }
                    return CurveHandle(segment: s, point: p, position: AutomationPoint(time: time, value: point.value))
                }
            }
        }
    }

    /// Where a point may go, in composition time: the whole sequence, or the selected clip.
    var curveEditRange: MediaTimeRange? {
        switch curveEditTarget {
        case .music: MediaTimeRange(start: .zero, end: project.duration)
        case .clipAudio: selectedClipID.flatMap { sequenceMap.entry(for: $0)?.compositionRange }
        case nil: nil
        }
    }

    /// Draws the edited curve by finger: each move adds the finger's position, and sweeping back
    /// over part of the stroke redraws it. Replaces what it passes over (drafted until
    /// `commitCurveDraft`), held to the selected clip for clip sound.
    func drawCurve(to position: AutomationPoint) {
        guard let target = curveEditTarget, let range = curveEditRange else { return }
        if engine.isPlaying { engine.pause() }
        let point = AutomationPoint(
            time: position.time.clamped(to: range.start, range.end), value: min(max(position.value, 0), 1))
        if let last = strokeLast {
            let lower = min(last.time, point.time)
            let upper = max(last.time, point.time)
            stroke.removeAll { $0.time == point.time || ($0.time > lower && $0.time < upper) }
        }
        stroke.insert(point, at: stroke.firstIndex { $0.time > point.time } ?? stroke.count)
        strokeLast = point
        curveDraft = WriteAutomationCommand(target: target, samples: stroke, drawn: true)
        applyLevels()
    }

    /// Drags a point to a composition-time position (drafted until `commitCurveDraft`).
    func dragCurvePoint(_ handle: CurveHandle, to position: AutomationPoint) {
        guard let target = curveEditTarget, let point = curvePoint(position) else { return }
        if engine.isPlaying { engine.pause() }
        curveDraft = EditCurvePointCommand(
            target: target, clipID: target == .clipAudio ? selectedClipID : nil,
            edit: .move(segment: handle.segment, point: handle.point, to: point))
        applyLevels()
    }

    func commitCurveDraft() {
        stroke = []
        strokeLast = nil
        guard let draft = curveDraft else { return }
        curveDraft = nil
        if draft is WriteAutomationCommand { selectedCurvePoint = nil }
        // A stroke that never spanned two moments draws nothing.
        if let write = draft as? WriteAutomationCommand,
            AutomationSegment(recorded: write.samples, sequenceDuration: project.duration) == nil
        {
            applyLevels()
            return
        }
        perform(draft)
        applyLevels()
        Haptics.detent()
    }

    /// Adds a point at a composition-time position: it bends the pass there, or starts a short one.
    func addCurvePoint(_ position: AutomationPoint) {
        guard let target = curveEditTarget, let point = curvePoint(position),
            let range = curveEditRange, range.contains(position.time) || position.time == range.end
        else {
            Haptics.warning()
            return
        }
        selectedCurvePoint = nil
        perform(
            EditCurvePointCommand(
                target: target, clipID: target == .clipAudio ? selectedClipID : nil, edit: .add(point)))
        applyLevels()
        Haptics.press()
    }

    func removeCurvePoint(_ handle: CurveHandle) {
        guard let target = curveEditTarget else { return }
        selectedCurvePoint = nil
        perform(
            EditCurvePointCommand(
                target: target, clipID: target == .clipAudio ? selectedClipID : nil,
                edit: .remove(segment: handle.segment, point: handle.point)))
        applyLevels()
        Haptics.detent()
    }

    /// A composition-time position in the edited curve's own time.
    private func curvePoint(_ position: AutomationPoint) -> AutomationPoint? {
        switch curveEditTarget {
        case .music:
            return position
        case .clipAudio:
            guard let id = selectedClipID, let entry = sequenceMap.entry(for: id) else { return nil }
            let local =
                position.time.clamped(to: entry.compositionRange.start, entry.compositionRange.end)
                - entry.compositionRange.start
            return AutomationPoint(
                time: entry.sourceStart + (entry.speed == 1 ? local : local.scaled(by: entry.speed)),
                value: position.value)
        case nil:
            return nil
        }
    }

    /// The composition time at which the selected clip plays a moment of its source.
    private func compositionTime(ofSource time: MediaTime) -> MediaTime? {
        guard let id = selectedClipID, let entry = sequenceMap.entry(for: id) else { return nil }
        let local = time - entry.sourceStart
        return entry.compositionRange.start + (entry.speed == 1 ? local : local.scaled(by: 1 / entry.speed))
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

    var isLandscape: Bool { project.exportSettings.isLandscape }

    /// Turns the picture between 9:16 and 16:9 (one undo step); the sequence rebuilds to match.
    func toggleOrientation() {
        perform(SetOrientationCommand(landscape: !isLandscape))
        Haptics.press()
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

    // MARK: Click and rhythm guides

    /// How long a guide is rendered: the sequence and half a minute more (at least a minute), in
    /// whole bars, so there's room to slide it and to keep cutting.
    func guideLength(bar: MediaTime) -> MediaTime {
        let wanted = max(60, project.duration.seconds + 30)
        let bars = max(1, Int((wanted / max(bar.seconds, 0.1)).rounded(.up)))
        return MediaTime(value: bar.value * Int64(bars), timescale: bar.timescale)
    }

    /// Renders a Quick Click or Billboards guide into the project's media and makes it the
    /// reference track, as one undoable step. Re-saving a guide of the same kind keeps where it
    /// was placed, its level and its lock; `beatOneAt` places its beat one there instead.
    func saveGuide(_ reference: MusicReference, named name: String, beatOneAt: MediaTime? = nil) async {
        importStatus = "Building guide…"
        do {
            var track = try await renderGuide(reference, named: name)
            if let previous = project.referenceAudio, previous.kind == reference.kind {
                track.offset = previous.offset
                track.volume = previous.volume
                track.isLocked = previous.isLocked
            }
            if let beatOneAt {
                track.offset = beatOneAt
                track.isLocked = false
            }
            finishMusicImport(track)
        } catch {
            finishMusicImport(error)
        }
    }

    /// Mix: scrubbing and the loop handles catch on the guide's beats.
    var snapsToBeats = false

    /// The reference track's beat grid, when it's a Quick Click or Billboards guide.
    var beatGrid: (guide: ClickGuide, offset: MediaTime)? {
        guard let music = project.referenceAudio,
            let grid = music.reference?.click ?? music.reference?.rhythm?.grid
        else { return nil }
        return (grid, music.offset)
    }

    /// The guide's beats (composition time) from `from` to `to` seconds; empty without a guide.
    func beatTimes(from: Double, to: Double) -> [MediaTime] {
        guard let (guide, offset) = beatGrid, to >= from else { return [] }
        let beat = 60 / guide.bpm
        let first = max(0, Int(((from - offset.seconds) / beat).rounded(.up)))
        let last = Int(((to - offset.seconds) / beat).rounded(.down))
        guard last >= first else { return [] }
        return (first...min(last, first + 2000)).map { offset + guide.beatTime($0) }
    }

    /// Renders a guide long enough for the sequence (see `guideLength`) into the project's media.
    private func renderGuide(_ reference: MusicReference, named name: String) async throws -> AudioTrack {
        let bar = reference.rhythm?.grid.barDuration ?? reference.click?.barDuration ?? MediaTime(seconds: 2)
        let length = guideLength(bar: bar)
        let clicks = reference.rhythm?.clicks(upTo: length) ?? reference.click?.clicks(upTo: length) ?? []
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        do {
            try GuideRenderer.write(clicks, duration: length, to: temp)
            var track = try await MediaImporter.adoptAudio(
                tempURL: temp, originalName: name, store: store, projectID: project.id)
            track.reference = reference
            return track
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    @ObservationIgnored private var isExtendingGuide = false

    /// A Quick Click or Billboards guide that the sequence has grown past (within 10 s of its end)
    /// is rendered again, longer, and folded into the edit that grew it: the same undo step takes
    /// both back. Everything else about the track (placement, level, lock) is kept.
    private func extendGuideIfNeeded() {
        guard !isExtendingGuide, let music = project.referenceAudio, let reference = music.reference,
            music.kind != .myMusic
        else { return }
        let covered = music.offset + music.duration
        guard project.duration + MediaTime(seconds: 10) > covered else { return }
        isExtendingGuide = true
        Task {
            defer { isExtendingGuide = false }
            guard var longer = try? await renderGuide(reference, named: music.originalFilename ?? "Guide") else {
                return
            }
            // Only if nothing replaced the guide meanwhile.
            guard let current = project.referenceAudio, current.fileName == music.fileName else { return }
            longer.id = current.id
            longer.offset = current.offset
            longer.volume = current.volume
            longer.isLocked = current.isLocked
            longer.lane = current.lane
            amend(SetReferenceAudioCommand(track: longer))
        }
    }

    /// Applies a follow-on change as part of the last edit, without an undo step of its own.
    private func amend(_ command: EditingCommand) {
        let previous = project
        guard (try? undoStack.amend(command, on: &project)) != nil else { return }
        didEdit(from: previous)
    }

    private func finishMusicImport(_ track: AudioTrack) {
        importStatus = nil
        var track = track
        if isInLightbox {
            // In LIGHTBOX the song starts at the playhead, on the first audio lane with room.
            track.offset = track.clampedOffset(currentTime, sequenceDuration: project.duration)
            guard let lane = project.firstClearAudioLane(for: track.timelineRange, excludingMusic: true) else {
                alertMessage = "No audio lane has room for the song at the playhead."
                Haptics.warning()
                return
            }
            track.lane = lane
        }
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

    /// Marks In or Out at the playhead on the clip playing there, in any state and without
    /// stopping playback (Watch's edge taps). After an In the clip plays on from its new start;
    /// after an Out the next clip follows on. Returns the clip's number, or nil when there's none.
    @discardableResult
    func markAtPlayhead(in isIn: Bool) -> Int? {
        if mode == .explore {
            guard let id = selectedClipID, let index = project.index(ofClip: id) else { return nil }
            isIn ? markIn() : markOut()
            return index + 1
        }
        guard let hit = sequenceMap.sourceTime(atComposition: currentTime),
            let entry = sequenceMap.entry(for: hit.clipID), let clip = project.clip(id: hit.clipID)
        else { return nil }
        let t = hit.sourceTime
        let range =
            isIn
            ? MediaTimeRange(start: t, end: max(clip.sourceRange.end, t + minimumClipDuration))
            : MediaTimeRange(start: min(clip.sourceRange.start, t - minimumClipDuration), end: t)
        perform(TrimClipCommand(clipID: clip.id, sourceRange: range))
        // The clip now starts at the marked moment, so carry on from its (unchanged) start.
        if isIn { rebuildSequence(keepingTime: entry.compositionRange.start) }
        Haptics.press()
        return entry.index + 1
    }

    /// Clears In and Out on the clip playing at the playhead, back to its whole source (a photo
    /// to its usual length), and plays on from the same moment. Returns the clip's number, or nil
    /// when there's no clip or nothing to clear.
    @discardableResult
    func clearMarksAtPlayhead() -> Int? {
        let id: UUID
        let sourceTime: MediaTime
        if mode == .explore {
            guard let selected = selectedClipID else { return nil }
            (id, sourceTime) = (selected, currentTime)
        } else {
            guard let hit = sequenceMap.sourceTime(atComposition: currentTime) else { return nil }
            (id, sourceTime) = (hit.clipID, hit.sourceTime)
        }
        guard let clip = project.clip(id: id), let source = project.source(for: clip),
            let index = project.index(ofClip: id), clip.sourceRange != source.defaultClipRange
        else { return nil }
        perform(TrimClipCommand(clipID: id, sourceRange: source.defaultClipRange))
        if mode != .explore, let resume = sequenceMap.compositionTime(clipID: id, sourceTime: sourceTime) {
            rebuildSequence(keepingTime: resume)
        }
        Haptics.press()
        return index + 1
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

    // MARK: Jog dial

    /// Frames per second of what the playhead moves through: the clip's source in Explore,
    /// the export frame grid otherwise.
    var jogFrameRate: Double {
        mode == .explore ? selectedSource?.frameRate ?? 30 : Double(project.exportSettings.frameRate)
    }

    /// The start of frame `n`, rounded up so a seek there shows that frame and not the one before.
    private func frameStart(_ n: Int) -> MediaTime {
        let timescale: Int32 = 60000
        return MediaTime(
            value: Int64((Double(n) / jogFrameRate * Double(timescale)).rounded(.up)), timescale: timescale)
    }

    /// The frame the playhead is on.
    private var currentFrame: Int { Int((currentTime.seconds * jogFrameRate + 1e-4).rounded(.down)) }

    /// Moves the playhead by whole frames (pausing playback), frame-accurately.
    func jog(by frames: Int) {
        guard frames != 0 else { return }
        if engine.isPlaying { engine.pause() }
        let last = max(0, Int((engine.duration.seconds * jogFrameRate).rounded(.up)) - 1)
        engine.seek(to: frameStart(min(max(currentFrame + frames, 0), last)).cmTime, precise: true)
    }

    /// Shuttles the playhead at `rate` (negative is reverse), or stops it with nil.
    func shuttle(_ rate: Float?) {
        if let rate {
            engine.shuttle(rate: rate)
        } else {
            engine.endShuttle()
        }
    }

    /// Mix, editing a curve: the point last tapped, which the dial then moves in time.
    var selectedCurvePoint: (segment: Int, point: Int)? {
        didSet { curvePointJog = nil }
    }
    /// The selected point as it was when the dial took hold of it, and how far it has moved.
    @ObservationIgnored private var curvePointJog: (handle: CurveHandle, frames: Int)?

    /// The selected point's handle, if it still exists.
    var selectedCurveHandle: CurveHandle? {
        guard let selected = selectedCurvePoint else { return nil }
        return curveHandles.first { $0.segment == selected.segment && $0.point == selected.point }
    }

    /// Moves the selected point by whole frames of composition time (drafted until `endJog`).
    func jogCurvePoint(by frames: Int) {
        guard frames != 0 else { return }
        if curvePointJog == nil, let handle = selectedCurveHandle { curvePointJog = (handle, 0) }
        guard var jog = curvePointJog else { return }
        jog.frames += frames
        curvePointJog = jog
        var moved = jog.handle.position
        moved.time = jog.handle.position.time + MediaTime(value: Int64(jog.frames), timescale: sequenceFrame.timescale)
        dragCurvePoint(jog.handle, to: moved)
        if let point = curveHandles.first(where: { $0.segment == jog.handle.segment && $0.point == jog.handle.point }) {
            engine.seek(to: point.position.time.cmTime, precise: true)
        }
    }

    /// The dial was let go: a point it moved is committed as one undo step.
    func endJog() {
        guard curvePointJog != nil else { return }
        curvePointJog = nil
        commitCurveDraft()
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

    // MARK: Record

    /// Takes brought in from the Record page this visit, for its count.
    private(set) var takesThisVisit = 0
    /// Takes from the Record page still being saved.
    private(set) var takesSaving = 0
    @ObservationIgnored private var takeSaving: Task<Void, Never>?

    func beginRecording() {
        engine.pause()
        takesThisVisit = 0
    }

    /// Adds a take from the Record page to the bin's TAKES folder; nothing goes straight onto
    /// the timeline. Takes save one after another in the order they were taken, so the shutter
    /// never waits for the last one to finish.
    /// Adds a take to the bin; with `saveToDevice`, a copy also goes to Photos (video and photo,
    /// through its look) or the Files app's Sounds folder (sound), without holding up the next.
    func addTake(_ take: RecordedTake, saveToDevice: Bool = false) async {
        let name = "Take " + Self.takeTime.string(from: .now)
        let previous = takeSaving
        takesSaving += 1
        importStatus = takesSaving == 1 ? "Saving take…" : "Saving \(takesSaving) takes…"
        let saving = Task {
            await previous?.value
            await saveTake(take, named: name, saveToDevice: saveToDevice)
        }
        takeSaving = saving
        await saving.value
        takesSaving -= 1
        if takesSaving > 0 { importStatus = takesSaving == 1 ? "Saving take…" : "Saving \(takesSaving) takes…" }
    }

    private func saveTake(_ take: RecordedTake, named name: String, saveToDevice: Bool) async {
        do {
            switch take {
            case .video(let url, let look):
                var source = try await MediaImporter.adopt(
                    tempURL: url, originalName: name, store: store, projectID: project.id)
                source.isTake = true
                source.look = look
                importStatus = nil
                perform(AddToBinCommand(sources: [source]))
                if saveToDevice {
                    let stored = store.mediaURL(for: source, projectID: project.id)
                    copyToDevice { try await DeviceSaver.saveVideo(stored, look: look) }
                }
            case .photo(let data, let look):
                var source = try await MediaImporter.adoptStill(
                    imageData: data, originalName: name, label: name, store: store, projectID: project.id)
                source.isTake = true
                source.look = look
                importStatus = nil
                perform(AddToBinCommand(sources: [source]))
                if saveToDevice { copyToDevice { try await DeviceSaver.savePhoto(data, look: look) } }
            case .sound(let url):
                let file = try await MediaImporter.adoptAudio(
                    tempURL: url, originalName: name, store: store, projectID: project.id)
                binSound(file, isTake: true)
                if saveToDevice {
                    let stored = mediaURL(forFile: file.fileName)
                    copyToDevice { try DeviceSaver.saveSound(stored, named: name) }
                }
            }
            takesThisVisit += 1
        } catch {
            importStatus = nil
            alertMessage = "The take couldn't be added. \(error.localizedDescription)"
            Haptics.warning()
        }
    }

    /// Makes a take's copy on the phone in the background; only a failure is reported.
    private func copyToDevice(_ copy: @escaping @Sendable () async throws -> Void) {
        Task {
            do {
                try await copy()
            } catch {
                alertMessage = "The take is in the bin, but its copy couldn't be saved. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Bin

    /// The bin is showing. Imports open it, so what came in can be picked for the timeline.
    var isBinOpen = false

    /// A piece of media in the bin: a picture (video or photo) or a sound.
    enum BinItem: Identifiable, Hashable {
        case picture(SourceAsset)
        case sound(BinSound)

        var id: UUID {
            switch self {
            case .picture(let source): source.id
            case .sound(let sound): sound.id
            }
        }
        var name: String {
            switch self {
            case .picture(let source): source.originalFilename ?? source.fileName
            case .sound(let sound): sound.originalFilename ?? sound.fileName
            }
        }
        var isTake: Bool {
            switch self {
            case .picture(let source): source.isTake
            case .sound(let sound): sound.isTake
            }
        }
        var importedAt: Date {
            switch self {
            case .picture(let source): source.importedAt
            case .sound(let sound): sound.importedAt
            }
        }
        var duration: MediaTime {
            switch self {
            case .picture(let source): source.duration
            case .sound(let sound): sound.duration
            }
        }
        var fileName: String {
            switch self {
            case .picture(let source): source.fileName
            case .sound(let sound): sound.fileName
            }
        }
    }

    /// Everything in the bin, newest first.
    var binItems: [BinItem] {
        (project.sources.map(BinItem.picture) + project.binSounds.map(BinItem.sound))
            .sorted { $0.importedAt > $1.importedAt }
    }

    func binUses(of id: UUID) -> Int { project.binUses(of: id) }

    func mediaURL(forFile fileName: String) -> URL {
        store.mediaDirectory(for: project.id).appendingPathComponent(fileName)
    }

    /// Media from the bin onto the timeline, in the order given. Pictures go on the end of the
    /// sequence, or at the playhead on the lowest lane with room in LIGHTBOX; sounds at the
    /// playhead on the first sound lane with room.
    func addFromBin(_ ids: [UUID]) {
        let items = ids.compactMap { id in binItems.first { $0.id == id } }
        let pictures = items.compactMap { item -> SourceAsset? in
            if case .picture(let source) = item { return source }
            return nil
        }
        if !pictures.isEmpty {
            importsAtPlayhead = isInLightbox
            importInsertIndex = nil
            addSources(pictures)
        }
        for case .sound(let sound) in items {
            let file = AudioTrack(
                fileName: sound.fileName, originalFilename: sound.originalFilename, duration: sound.duration)
            addSound(file)
        }
    }

    /// Takes media out of the bin and off the timeline wherever it's used (undo brings it back).
    func removeFromBin(_ ids: Set<UUID>) {
        perform(RemoveFromBinCommand(ids: ids))
    }

    /// Gives a picture in the bin a look, or takes it off (nil); every clip of it follows.
    func setLook(_ look: Look?, forSource id: UUID) {
        perform(SetSourceLookCommand(sourceID: id, look: look))
    }

    func renameMedia(_ id: UUID, to name: String) {
        perform(RenameMediaCommand(id: id, name: name))
    }

    private static let takeTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH.mm.ss"
        return formatter
    }()

    /// Demo clips into the sequence at `index`, or at the playhead on the lowest lane with room.
    func addDemoClips() async {
        importStatus = "Generating demo clips…"
        do {
            let sources = try await DemoMediaGenerator.makeDemoSources(store: store, projectID: project.id)
            finishImport(sources, [])
        } catch {
            finishImport([], [error])
        }
    }

    /// What was brought in goes to the bin, which opens to show it; nothing goes straight onto
    /// the timeline.
    private func finishImport(_ sources: [SourceAsset], _ errors: [Error]) {
        importStatus = nil
        if !sources.isEmpty {
            perform(AddToBinCommand(sources: sources))
            isBinOpen = true
        }
        if !errors.isEmpty {
            alertMessage = errors.map { $0.localizedDescription }.joined(separator: "\n")
        } else if !sources.isEmpty {
            Haptics.success()
        }
    }
}
