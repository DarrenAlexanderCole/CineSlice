import EditCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One elastic workspace. Preview and transport stay put; the deck below
/// changes with the contextual state (Arrange, Explore, Mix). Release is the export sheet.
/// Watch hides everything but the picture.
struct WorkspaceView: View {
    @State var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What a picker was opened for. One picker of each kind is shared, since
    /// SwiftUI only honours one `photosPicker`/`fileImporter` per view.
    private enum PickPurpose { case clips, music }

    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var pickPurpose = PickPurpose.clips
    @State private var showExport = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isWatching = false

    var body: some View {
        ZStack {
            if isWatching {
                // The editing controls go away entirely: nothing to reach with VoiceOver, nothing to redraw.
                WatchView(model: model) { setWatching(false) }
                    .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    topBar
                    preview
                    deck
                }
                .transition(.opacity)
            }
        }
        .background(Theme.obsidian.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
        .onAppear { model.open() }
        .onDisappear { model.close() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.saveNow()
                model.engine.pause()
            }
        }
        .photosPicker(
            isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: pickPurpose == .clips ? 20 : 1,
            matching: pickPurpose == .clips ? .any(of: [.videos, .images]) : .videos, preferredItemEncoding: .current
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            switch pickPurpose {
            case .clips: Task { await model.importPhotos(items) }
            case .music: if let item = items.first { Task { await model.importMusic(fromVideo: item) } }
            }
        }
        .fileImporter(
            isPresented: $showFiles, allowedContentTypes: pickPurpose == .clips ? [.movie, .image] : [.audio],
            allowsMultipleSelection: pickPurpose == .clips
        ) { result in
            guard case .success(let urls) = result else { return }
            switch pickPurpose {
            case .clips: Task { await model.importFiles(urls) }
            case .music: if let url = urls.first { Task { await model.importMusicFile(url) } }
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .alert(
            "Heads up",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.instrument())
            .accessibilityLabel("Projects")
            Text(model.project.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.instrument())
            .disabled(model.undoName == nil)
            .accessibilityLabel(model.undoName.map { "Undo \($0)" } ?? "Undo")
            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.instrument())
            .disabled(model.redoName == nil)
            .accessibilityLabel(model.redoName.map { "Redo \($0)" } ?? "Redo")
            Button {
                model.engine.pause()
                showExport = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.instrument())
            .disabled(model.project.clips.isEmpty)
            .accessibilityLabel("Export")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color.black
            if model.project.clips.isEmpty {
                emptyState
            } else {
                PlayerView(player: model.engine.player)
            }
            VStack {
                HStack {
                    GlassChip {
                        HStack(spacing: 6) {
                            LED(isOn: model.engine.isPlaying)
                            Text(model.mode.title.uppercased())
                                .font(Theme.caption)
                                .foregroundStyle(Theme.label)
                        }
                    }
                    Spacer()
                    if !model.project.clips.isEmpty {
                        GlassChip {
                            HStack(spacing: 4) {
                                TimecodeText(time: model.currentTime, frameRate: frameRate, size: 13)
                                Text("/").foregroundStyle(Theme.secondaryLabel)
                                TimecodeText(
                                    time: MediaTime(model.engine.duration), frameRate: frameRate, size: 13,
                                    color: Theme.secondaryLabel)
                            }
                        }
                    }
                }
                Spacer()
                if let status = model.importStatus {
                    GlassChip {
                        HStack(spacing: 8) {
                            ProgressView().tint(Theme.signal)
                            Text(status).font(Theme.caption).foregroundStyle(Theme.label)
                        }
                    }
                }
                if !model.project.clips.isEmpty {
                    HStack {
                        Spacer()
                        Button {
                            setWatching(true)
                        } label: {
                            GlassChip {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.label)
                            }
                            .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Watch")
                        .accessibilityHint("Shows just the video and plays it. Tap the video for controls.")
                    }
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 8)
    }

    /// Watch starts playback, since it is for watching; leaving it keeps whatever is playing.
    private func setWatching(_ on: Bool) {
        if on, !model.engine.isPlaying { model.engine.play() }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { isWatching = on }
    }

    private var frameRate: Double {
        model.mode == .explore
            ? (model.selectedSource?.frameRate ?? 30) : Double(model.project.exportSettings.frameRate)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("Bring in some footage")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.label)
            Text("Pick several videos. They'll line up in order and play as one 9:16 sequence.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            HStack(spacing: 10) {
                Button("Photos") { pick(.clips, photos: true) }.buttonStyle(.instrument(.prominent))
                Button("Files") { pick(.clips, photos: false) }.buttonStyle(.instrument(.dark))
            }
            Button("Demo clips") { Task { await model.addDemoClips() } }
                .buttonStyle(.instrument(.dark))
                .accessibilityHint("Generates three test clips: landscape, portrait and square")
        }
        .padding()
    }

    // MARK: Deck

    private func pick(_ purpose: PickPurpose, photos: Bool) {
        pickPurpose = purpose
        if photos { showPhotos = true } else { showFiles = true }
    }

    private var deck: some View {
        VStack(spacing: 12) {
            if !model.project.clips.isEmpty {
                StateSwitcher(model: model)
            }
            switch model.mode {
            case .arrange:
                ArrangeDeck(
                    model: model,
                    onAddPhotos: { pick(.clips, photos: true) },
                    onAddFiles: { pick(.clips, photos: false) }
                )
                .transition(.opacity)
            case .explore:
                ExploreDeck(model: model)
                    .transition(.opacity)
            case .mix:
                MixDeck(
                    model: model,
                    onAddMusicFile: { pick(.music, photos: false) },
                    onAddMusicFromVideo: { pick(.music, photos: true) }
                )
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Theme.instrument, Theme.obsidian], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 22) }
                .ignoresSafeArea(edges: .bottom)
        )
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.mode)
    }
}

/// Just the picture, edge to edge on black, with the status bar and home indicator out of the
/// way. Tapping shows play/pause and Done for a few seconds; swiping down also leaves.
/// With VoiceOver the controls stay up.
private struct WatchView: View {
    var model: WorkspaceModel
    var onDone: () -> Void

    @State private var showsControls = false
    @State private var hideTask: Task<Void, Never>?
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerView(player: model.engine.player)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            if showsControls || voiceOver {
                controls.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { setControls(!showsControls) }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { g in
                if g.translation.height > 100, abs(g.translation.width) < g.translation.height { onDone() }
            }
        )
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onDisappear { hideTask?.cancel() }
    }

    private var controls: some View {
        VStack {
            HStack {
                GlassChip {
                    TimecodeText(
                        time: model.currentTime, frameRate: Double(model.project.exportSettings.frameRate), size: 13)
                }
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.instrument())
                    .accessibilityHint("Back to editing")
            }
            Spacer()
            Button {
                model.engine.togglePlay()
                setControls(true)
            } label: {
                Image(systemName: model.engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 64, height: 56)
            }
            .buttonStyle(.instrument(.key, active: model.engine.isPlaying))
            .accessibilityLabel(model.engine.isPlaying ? "Pause" : "Play")
        }
        .padding(16)
    }

    /// Shows or hides the controls; shown, they fade out again after a few seconds.
    private func setControls(_ on: Bool) {
        hideTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsControls = on }
        guard on else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { showsControls = false }
        }
    }
}

/// Shared transport: frame step, play/pause, loop.
struct TransportRow<Leading: View, Trailing: View>: View {
    var model: WorkspaceModel
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 0)
            Button {
                model.step(-1)
            } label: {
                Image(systemName: "backward.frame.fill")
            }
            .buttonStyle(.instrument())
            .accessibilityLabel("Back one frame")
            Button {
                model.engine.togglePlay()
            } label: {
                Image(systemName: model.engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 44, height: 40)
            }
            .buttonStyle(.instrument(.key, active: model.engine.isPlaying))
            .accessibilityLabel(model.engine.isPlaying ? "Pause" : "Play")
            Button {
                model.step(1)
            } label: {
                Image(systemName: "forward.frame.fill")
            }
            .buttonStyle(.instrument())
            .accessibilityLabel("Forward one frame")
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// Explore loops the clip's in/out. Arrange and Mix loop the bracketed region of the
/// sequence: tap toggles it, and holding opens Loop In / Loop Out at the playhead,
/// loop the selected clip, or loop everything.
struct LoopButton: View {
    var model: WorkspaceModel

    private var isExplore: Bool { model.mode == .explore }
    private var isOn: Bool { isExplore ? model.loopSelection : model.activeLoop != nil }

    var body: some View {
        if isExplore {
            Button {
                model.loopSelection.toggle()
                Haptics.tap()
            } label: {
                Image(systemName: "repeat")
            }
            .buttonStyle(.instrument(.dark, active: isOn))
            .disabled(model.selectedClip == nil)
            .accessibilityLabel("Loop in to out")
            .accessibilityValue(isOn ? "On" : "Off")
        } else {
            Menu {
                Button(action: model.setLoopIn) { Label("Loop In at playhead", systemImage: "chevron.left.to.line") }
                Button(action: model.setLoopOut) {
                    Label("Loop Out at playhead", systemImage: "chevron.right.to.line")
                }
                Button(action: model.loopSelectedClip) { Label("Loop selected clip", systemImage: "film") }
                    .disabled(model.selectedClipID == nil)
                Button(action: model.loopWholeSequence) {
                    Label("Loop whole sequence", systemImage: "arrow.left.and.right")
                }
            } label: {
                Image(systemName: "repeat")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.signal : Theme.ivory)
                    .frame(width: Theme.minTouch + 20, height: Theme.minTouch)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.instrument, Theme.obsidian], startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(isOn ? Theme.signal : Theme.hairline, lineWidth: isOn ? 1.5 : 1)
                            .shadow(color: isOn ? Theme.signal.opacity(0.6) : .clear, radius: 6)
                    )
            } primaryAction: {
                model.toggleLoop()
            }
            .disabled(model.project.clips.isEmpty)
            .accessibilityLabel("Loop region")
            .accessibilityValue(isOn ? "On" : "Off")
            .accessibilityHint("Toggles the loop. Hold for Loop In, Loop Out and more.")
        }
    }
}

/// Switches among the workspace's contextual states. Preview and transport stay put.
struct StateSwitcher: View {
    var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(WorkspaceModel.Mode.allCases, id: \.self) { mode in
                let isCurrent = model.mode == mode
                Button {
                    model.setMode(mode)
                } label: {
                    Text(mode.title).frame(maxWidth: .infinity)
                }
                .buttonStyle(.instrument(.dark, active: isCurrent))
                .disabled(mode == .explore && model.selectedClip == nil)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
    }
}
