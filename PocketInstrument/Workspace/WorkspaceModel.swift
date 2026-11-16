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
    enum Mode: String { case arrange, explore }

    private(set) var project: Project
    var mode: Mode = .arrange
    var selectedClipID: UUID?
    /// Loops the selected clip (Arrange) or its in/out range (Explore) instead of everything.
    var loopSelection = false { didSet { updateLoopRange() } }

    /// In-progress trim while a handle is being dragged (committed on release as one undo step).
    var draftRange: MediaTimeRange?

    var importStatus: String?
    var alertMessage: String?
    private(set) var isRebuilding = false

    let engine = PlaybackEngine()
    let store: ProjectStore

    @ObservationIgnored private var undoStack = UndoStack()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
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

    // MARK: Lifecycle

    func open() {
        rebuildSequence(keepingTime: .zero)
    }

    func close() {
        saveNow()
        engine.tearDown()
        rebuildTask?.cancel()
    }

    // MARK: Commands / undo

    func perform(_ command: EditingCommand) {
        do {
            try undoStack.perform(command, on: &project)
            didEdit()
        } catch {
            alertMessage = "\(command.actionName) failed: \(error.localizedDescription)"
            Haptics.warning()
        }
    }

    func undo() {
        guard undoStack.undo(&project) != nil else { return }
        didEdit()
    }

    func redo() {
        guard undoStack.redo(&project) != nil else { return }
        didEdit()
    }

    private func didEdit() {
        undoName = undoStack.undoActionName
        redoName = undoStack.redoActionName
        if let id = selectedClipID, project.clip(id: id) == nil {
            selectedClipID = project.clips.first?.id
        }
        if mode == .explore, selectedClip == nil { mode = .arrange }
        scheduleSave()
        refreshPlayback()
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
        case .arrange:
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
                let built = try await CompositionBuilder.build(
                    project: snapshot,
                    renderSize: CGSize(width: snapshot.exportSettings.width, height: snapshot.exportSettings.height),
                    frameRate: Int32(snapshot.exportSettings.frameRate),
                    includeClipAudio: snapshot.exportSettings.includeClipAudio,
                    mediaURL: {
                        store.isMissing($0, projectID: snapshot.id)
                            ? nil : store.mediaURL(for: $0, projectID: snapshot.id)
                    })
                guard !Task.isCancelled, self.mode == .arrange else { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
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
        guard loopSelection, let clip = selectedClip else {
            engine.loopRange = nil
            return
        }
        switch mode {
        case .arrange:
            engine.loopRange = sequenceMap.entry(for: clip.id)?.compositionRange.cmTimeRange
        case .explore:
            engine.loopRange = (draftRange ?? clip.sourceRange).cmTimeRange
        }
    }

    // MARK: Selection & modes

    func select(_ clipID: UUID) {
        selectedClipID = clipID
        Haptics.detent()
        if mode == .arrange, let start = sequenceMap.compositionStart(of: clipID) {
            engine.seek(to: start.cmTime, precise: true)
        }
        updateLoopRange()
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

    func returnToArrange() {
        mode = .arrange
        draftRange = nil
        let start = selectedClipID.flatMap { sequenceMap.compositionStart(of: $0) } ?? .zero
        rebuildSequence(keepingTime: start, resume: false)
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
    func setIncludeClipAudio(_ include: Bool) {
        var settings = project.exportSettings
        settings.includeClipAudio = include
        perform(SetExportSettingsCommand(settings: settings))
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
