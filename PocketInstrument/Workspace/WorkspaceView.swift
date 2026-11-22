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
            .buttonStyle(.instrument(height: 36))
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
            .buttonStyle(.instrument(height: 36))
            .disabled(model.undoName == nil)
            .accessibilityLabel(model.undoName.map { "Undo \($0)" } ?? "Undo")
            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.instrument(height: 36))
            .disabled(model.redoName == nil)
            .accessibilityLabel(model.redoName.map { "Redo \($0)" } ?? "Redo")
            Button {
                model.engine.pause()
                showExport = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.instrument(height: 36))
            .disabled(model.project.clips.isEmpty)
            .accessibilityLabel("Export")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: Preview

    private var preview: some View {
        ZStack {
            Color.black
            if model.project.clips.isEmpty {
                emptyState
            } else {
                PlayerView(player: model.engine.player)
                    .padding(Viewfinder.margin)
                Viewfinder(
                    aspect: pictureAspect,
                    showsFeedCrop: model.mode != .explore && !model.isLandscape && !model.isCropping
                )
                .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: pictureAspect)
                if model.isCropping {
                    CropFrame(model: model, aspect: pictureAspect)
                }
            }
            VStack {
                HStack {
                    GlassChip(compact: true) {
                        HStack(spacing: 4) {
                            LED(isOn: model.engine.isPlaying)
                            Text(model.mode.title.uppercased())
                                .font(Theme.mono(9, weight: .bold))
                                .foregroundStyle(Theme.label)
                        }
                    }
                    Spacer()
                    if !model.project.clips.isEmpty {
                        // Small and stacked, so it sits on the gate off the picture.
                        GlassChip(compact: true) {
                            VStack(alignment: .trailing, spacing: 0) {
                                TimecodeText(time: model.currentTime, frameRate: frameRate, size: 10)
                                TimecodeText(
                                    time: MediaTime(model.engine.duration), frameRate: frameRate, size: 7,
                                    color: Theme.secondaryLabel)
                            }
                            .padding(.vertical, 2)
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
                        if model.mode != .explore { orientationKey }
                        Spacer()
                        Button {
                            setWatching(true)
                        } label: {
                            GlassChip(compact: true) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.label)
                            }
                            .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch, alignment: .bottomTrailing)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Watch")
                        .accessibilityHint("Shows just the video and plays it. Tap the video for controls.")
                    }
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.black.opacity(0.8), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background(ViewerHousing(label: housingLabel))
        .padding(.horizontal, 6)
    }

    /// Cast into the housing's bottom rail.
    private var housingLabel: String {
        model.mode == .explore
            ? "CINESLICE · SOURCE" : "CINESLICE · \(model.project.exportSettings.aspectLabel) VIEWER"
    }

    /// Width over height of what the preview shows: the clip's source in Explore, else the sequence's frame.
    private var pictureAspect: CGFloat {
        if model.mode == .explore, let source = model.selectedSource, source.height > 0 {
            return CGFloat(source.width) / CGFloat(source.height)
        }
        let settings = model.project.exportSettings
        return CGFloat(settings.width) / CGFloat(max(settings.height, 1))
    }

    /// Turns the picture between 9:16 and 16:9; the viewfinder turns with it.
    private var orientationKey: some View {
        Button {
            model.toggleOrientation()
        } label: {
            GlassChip(compact: true) {
                HStack(spacing: 4) {
                    Image(systemName: model.isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                        .font(.system(size: 10, weight: .bold))
                    Text(model.project.exportSettings.aspectLabel)
                        .font(Theme.mono(9, weight: .bold))
                }
                .foregroundStyle(Theme.label)
            }
            .frame(minHeight: Theme.minTouch, alignment: .bottomLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Picture shape")
        .accessibilityValue(model.isLandscape ? "16:9 horizontal" : "9:16 vertical")
        .accessibilityHint("Turns the picture between vertical and horizontal.")
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
        VStack(spacing: 8) {
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
            case .audio:
                AudioDeck(model: model)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Chassis().shadow(color: .black.opacity(0.7), radius: 8, y: -2).ignoresSafeArea(edges: .bottom))
        .padding(.top, 6)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.mode)
    }
}

/// Just the picture, edge to edge on black, with the status bar and home indicator out of the
/// way. A tap anywhere shows play/pause, In/Out and Done for a few seconds; a triple tap or a
/// swipe down leaves. Nothing marks from a tap on the picture itself, so watching stays
/// uninterrupted. With VoiceOver the controls stay up.
private struct WatchView: View {
    var model: WorkspaceModel
    var onDone: () -> Void

    @State private var showsControls = false
    @State private var hideTask: Task<Void, Never>?
    /// The last mark, flashed big: In on the left, Out on the right, a clear in the middle.
    @State private var flash: (mark: Mark, clip: Int)?
    /// Recent taps on the picture, to catch a triple tap without delaying single ones.
    @State private var taps: [Date] = []

    enum Mark {
        case markIn, markOut, cleared

        var title: String {
            switch self {
            case .markIn: "IN"
            case .markOut: "OUT"
            case .cleared: "CLEARED"
            }
        }

        /// In flashes on the left, Out on the right, a clear in the middle.
        var alignment: Alignment {
            switch self {
            case .markIn: .leading
            case .markOut: .trailing
            case .cleared: .center
            }
        }
    }
    @State private var flashTask: Task<Void, Never>?

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerView(player: model.engine.player)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            if let flash { flashView(flash) }
            if showsControls || voiceOver {
                controls.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tapped() }
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { g in
                if g.translation.height > 100, abs(g.translation.width) < g.translation.height { onDone() }
            }
        )
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onDisappear {
            hideTask?.cancel()
            flashTask?.cancel()
        }
    }

    /// A tap shows or hides the controls; the third in quick succession leaves.
    private func tapped() {
        let now = Date()
        taps = (taps + [now]).filter { now.timeIntervalSince($0) < 0.6 }
        if taps.count >= 3 {
            taps = []
            onDone()
        } else {
            setControls(!showsControls)
        }
    }

    private func mark(in isIn: Bool) {
        show(isIn ? .markIn : .markOut, clip: model.markAtPlayhead(in: isIn))
    }

    private func clearMarks() {
        show(.cleared, clip: model.clearMarksAtPlayhead())
    }

    private func show(_ mark: Mark, clip: Int?) {
        guard let clip else {
            Haptics.warning()
            return
        }
        flashTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { flash = (mark, clip) }
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.3)) { flash = nil }
        }
    }

    /// The mark, big and on its own side of the screen (a clear in the middle).
    private func flashView(_ flash: (mark: Mark, clip: Int)) -> some View {
        VStack(spacing: 4) {
            Text(flash.mark.title)
                .font(.system(size: 44, weight: .heavy, design: .monospaced))
                .foregroundStyle(Theme.signal)
            Text(String(format: "CLIP %02d", flash.clip))
                .font(Theme.mono(12))
                .foregroundStyle(Theme.ivory)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.55)))
        .frame(maxWidth: .infinity, alignment: flash.mark.alignment)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityHidden(true)
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
            HStack {
                markKey(in: true)
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
                Spacer()
                markKey(in: false)
            }
        }
        .padding(16)
    }

    /// IN and OUT beside play: marks the clip that's playing, without stopping.
    private func markKey(in isIn: Bool) -> some View {
        Button(isIn ? "In" : "Out") {
            mark(in: isIn)
            setControls(true)
        }
        .buttonStyle(.instrument())
        .accessibilityLabel(isIn ? "Mark in at playhead" : "Mark out at playhead")
        .accessibilityHint("Trims the clip that's playing.")
        .accessibilityAction(named: "Clear in and out") { clearMarks() }
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

/// Shared transport: the jog wheel between frame-step keys, then play/pause between each
/// state's own keys.
struct TransportRow<Leading: View, Trailing: View>: View {
    var model: WorkspaceModel
    /// What the wheel moves: by default it jogs and shuttles the playhead. Mix hands it a curve
    /// point instead (`jogTitle` "POINT", its own `onJog`, and no shuttle).
    var jogTitle = "JOG"
    var onJog: ((Int) -> Void)?
    var shuttles = true
    var onJogEnd: () -> Void = {}
    /// One row: play, the wheel, then `trailing` (`leading` and the frame-step keys are left out;
    /// the wheel steps frames itself).
    var compact = false
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if compact {
            HStack(alignment: .bottom, spacing: 6) {
                playKey(diameter: 44).padding(.bottom, 4)
                wheel
                trailing.padding(.bottom, 4)
            }
        } else {
            full
        }
    }

    private var wheel: some View {
        JogDial(
            title: jogTitle, onStep: onJog ?? { model.jog(by: $0) },
            onShuttle: shuttles ? { model.shuttle($0) } : nil, onEnd: onJogEnd
        )
        .disabled(model.project.clips.isEmpty)
    }

    private func playKey(diameter: CGFloat) -> some View {
        Button {
            model.engine.togglePlay()
        } label: {
            Image(systemName: model.engine.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: diameter * 0.4, weight: .heavy))
        }
        .buttonStyle(.round(diameter, lit: model.engine.isPlaying, prominent: true))
        .disabled(model.project.clips.isEmpty)
        .accessibilityLabel(model.engine.isPlaying ? "Pause" : "Play")
    }

    private var full: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 2) {
                StepKey(model: model, frames: -1)
                wheel
                StepKey(model: model, frames: 1)
            }
            .disabled(model.project.clips.isEmpty)
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 0)
                playKey(diameter: 50)
                Spacer(minLength: 0)
                trailing
            }
        }
    }
}

/// A round key stepping one frame back or forward, at either end of the jog wheel.
struct StepKey: View {
    var model: WorkspaceModel
    var frames: Int

    var body: some View {
        Button {
            model.step(frames)
        } label: {
            Image(systemName: frames < 0 ? "backward.frame.fill" : "forward.frame.fill")
        }
        .buttonStyle(.round(34))
        .padding(.bottom, 9)
        .accessibilityLabel(frames < 0 ? "Back one frame" : "Forward one frame")
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
            .buttonStyle(.round(42, lit: isOn))
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
                RoundKeyFace(diameter: 42, isLit: isOn) { Image(systemName: "repeat") }
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
        // The state keys in one recessed slot, like a rocker; the current one is lit.
        HStack(spacing: 6) {
            ForEach(WorkspaceModel.Mode.allCases, id: \.self) { mode in
                let isCurrent = model.mode == mode
                Button {
                    model.setMode(mode)
                } label: {
                    HStack(spacing: 4) {
                        // A split being made carries on whatever state is showing: say so here too.
                        if mode == .audio, model.isProcessingVoice { LED(isOn: true, blinks: true) }
                        Text(mode.title).font(Theme.mono(10, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                }
                .accessibilityValue(mode == .audio && model.isProcessingVoice ? "Processing sound" : "")
                .buttonStyle(.instrument(.dark, active: isCurrent, height: 28))
                .disabled(mode == .explore && model.selectedClip == nil)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .recessed(cornerRadius: 11, padding: 3)
    }
}

/// A viewfinder around the picture: everything outside it is a machined film gate, a brushed
/// metal plate with a bevelled aperture cut to the picture's shape, screwed down beside it, with
/// engraved rulers along each edge of the aperture. Inside are corner brackets, a centre cross and
/// a soft vignette. On a vertical sequence, faint lines mark the 4:5 crop a feed shows. It turns
/// (the aperture springs between shapes) when the picture changes between 9:16 and 16:9.
private struct Viewfinder: View, Animatable {
    /// Width over height of the picture.
    var aspect: CGFloat
    var showsFeedCrop: Bool

    /// Room round the picture for the rulers; the player is inset by the same.
    static let margin: CGFloat = 14

    var animatableData: CGFloat {
        get { aspect }
        set { aspect = newValue }
    }

    /// The picture's frame in a preview of `bounds`, fitted inside the margin the way the
    /// player (inset by the margin) fits it.
    static func pictureRect(aspect: CGFloat, in bounds: CGSize) -> CGRect {
        let inner = CGSize(width: bounds.width - 2 * margin, height: bounds.height - 2 * margin)
        guard aspect > 0, inner.width > 0, inner.height > 0 else { return .zero }
        let fitsWidth = inner.width / inner.height < aspect
        let size =
            fitsWidth
            ? CGSize(width: inner.width, height: inner.width / aspect)
            : CGSize(width: inner.height * aspect, height: inner.height)
        return CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
            height: size.height)
    }

    var body: some View {
        GeometryReader { geo in
            let rect = Self.pictureRect(aspect: aspect, in: geo.size).insetBy(dx: 0.5, dy: 0.5)
            let hood = Path { p in
                p.addRect(CGRect(origin: .zero, size: geo.size))
                p.addRoundedRect(in: rect, cornerSize: CGSize(width: 4, height: 4))
            }
            let plate = hood.fill(style: FillStyle(eoFill: true))
            ZStack {
                // The gate plate: brushed metal, lit from above.
                LinearGradient(
                    colors: [Color(hex: 0xA7AB9C), Color(hex: 0x878C7B), Color(hex: 0x5F6456)], startPoint: .top,
                    endPoint: .bottom
                )
                .overlay(BrushedMetal(strength: 1.6).blendMode(.multiply))
                .overlay(Grain(opacity: 0.55))
                .mask(plate)
                // The aperture's bevel: its upper edge in shadow, its lower edge catching the light.
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        LinearGradient(
                            colors: [Color.black.opacity(0.75), Color.black.opacity(0.3), Color.white.opacity(0.6)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 8
                    )
                    .frame(width: rect.width + 8, height: rect.height + 8)
                    .position(x: rect.midX, y: rect.midY)
                    .mask(plate)
                screws(bounds: geo.size, rect: rect)
                // Inside the picture, the corners fall off a little.
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        RadialGradient(
                            colors: [.clear, .clear, .black.opacity(0.35)], center: .center, startRadius: 0,
                            endRadius: max(rect.width, rect.height) * 0.75)
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                Canvas { context, _ in draw(in: &context, rect: rect) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Pairs of screws holding the plate down, where it is wide enough beside the aperture.
    @ViewBuilder
    private func screws(bounds: CGSize, rect: CGRect) -> some View {
        let side = rect.minX
        let band = rect.minY
        if side > 44 {
            ForEach([rect.minX / 2, bounds.width - side / 2], id: \.self) { x in
                ForEach([-14.0, 14.0], id: \.self) { dy in
                    Screw(angle: 25 + dy * 3).position(x: x, y: rect.midY + dy)
                }
            }
        } else if band > 40 {
            ForEach([band / 2, bounds.height - band / 2], id: \.self) { y in
                ForEach([-70.0, -50.0, 50.0, 70.0], id: \.self) { dx in
                    Screw(angle: 40 + dx).position(x: rect.midX + dx, y: y)
                }
            }
        }
    }

    private func draw(in context: inout GraphicsContext, rect: CGRect) {
        // Engraved into the plate.
        let tick = Color.black.opacity(0.6)
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.black.opacity(0.85)), lineWidth: 1.5)

        // Rulers just outside each edge: 40 divisions, longer every fifth, Signal at the middle.
        func ruler(from a: CGPoint, to b: CGPoint, outward: CGVector) {
            for i in 0...40 {
                let f = CGFloat(i) / 40
                let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                let major = i % 5 == 0
                let length: CGFloat = i == 20 ? 12 : (major ? 8 : 4)
                var line = Path()
                line.move(to: CGPoint(x: p.x + outward.dx * 6, y: p.y + outward.dy * 6))
                line.addLine(to: CGPoint(x: p.x + outward.dx * (6 + length), y: p.y + outward.dy * (6 + length)))
                context.stroke(
                    line, with: .color(i == 20 ? Theme.signal : (major ? tick : tick.opacity(0.5))),
                    lineWidth: i == 20 ? 1.5 : 1)
            }
        }
        ruler(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.minX, y: rect.maxY),
            outward: CGVector(dx: -1, dy: 0))
        ruler(
            from: CGPoint(x: rect.maxX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            outward: CGVector(dx: 1, dy: 0))
        ruler(
            from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY),
            outward: CGVector(dx: 0, dy: -1))
        ruler(
            from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.maxY),
            outward: CGVector(dx: 0, dy: 1))

        // Corner brackets just inside the frame.
        let inset: CGFloat = 10
        let arm = min(rect.width, rect.height) * 0.09
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX + inset, y: rect.minY + inset), 1, 1),
            (CGPoint(x: rect.maxX - inset, y: rect.minY + inset), -1, 1),
            (CGPoint(x: rect.minX + inset, y: rect.maxY - inset), 1, -1),
            (CGPoint(x: rect.maxX - inset, y: rect.maxY - inset), -1, -1),
        ]
        for (c, dx, dy) in corners {
            var bracket = Path()
            bracket.move(to: CGPoint(x: c.x + dx * arm, y: c.y))
            bracket.addLine(to: c)
            bracket.addLine(to: CGPoint(x: c.x, y: c.y + dy * arm))
            context.stroke(
                bracket, with: .color(Theme.signal.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }

        // Centre cross.
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var cross = Path()
        cross.move(to: CGPoint(x: c.x - 9, y: c.y))
        cross.addLine(to: CGPoint(x: c.x + 9, y: c.y))
        cross.move(to: CGPoint(x: c.x, y: c.y - 9))
        cross.addLine(to: CGPoint(x: c.x, y: c.y + 9))
        context.stroke(cross, with: .color(Theme.ivory.opacity(0.4)), lineWidth: 1)

        // The 4:5 crop a feed shows of a vertical video: faint dashed lines with a label.
        if showsFeedCrop {
            let cropHeight = min(rect.width * 5 / 4, rect.height)
            let top = rect.midY - cropHeight / 2
            let bottom = rect.midY + cropHeight / 2
            for y in [top, bottom] {
                var line = Path()
                line.move(to: CGPoint(x: rect.minX + 4, y: y))
                line.addLine(to: CGPoint(x: rect.maxX - 4, y: y))
                context.stroke(
                    line, with: .color(Theme.ivory.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
            }
            context.draw(
                Text("4:5").font(Theme.mono(8, weight: .bold)).foregroundStyle(Theme.ivory.opacity(0.45)),
                at: CGPoint(x: rect.maxX - 16, y: top + 8))
        }
    }
}

/// The viewer's metal housing: a cast, brushed frame round the hood whatever the picture's shape,
/// held by slotted screws at its sides, with its name cast into the bottom rail.
private struct ViewerHousing: View {
    var label: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        shape.fill(
            LinearGradient(
                colors: [Color(hex: 0x9EA391), Color(hex: 0x737966), Color(hex: 0x4E5444)], startPoint: .top,
                endPoint: .bottom)
        )
        .overlay(BrushedMetal(strength: 1.2).clipShape(shape).blendMode(.multiply))
        // Hammered enamel: a coarse grain over the brushing.
        .overlay(Grain(opacity: 0.7).clipShape(shape))
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.55), Color.white.opacity(0.08), Color.black.opacity(0.5)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1.5)
        )
        // The lip where the hood opens: a dark shadow line just inside the frame.
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.black.opacity(0.75), Color.white.opacity(0.35)], startPoint: .top,
                        endPoint: .bottom),
                    lineWidth: 2.5
                )
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 18)
        )
        .overlay {
            HStack {
                Screw(angle: 70)
                Spacer()
                Screw(angle: -20)
            }
            .padding(.horizontal, 1.5)
        }
        .overlay(alignment: .bottom) {
            // Cast lettering: dark, with a lit edge below.
            Text(label)
                .font(Theme.mono(7, weight: .heavy))
                .tracking(2)
                .foregroundStyle(Color.black.opacity(0.55))
                .shadow(color: .white.opacity(0.35), radius: 0, y: 0.8)
                .padding(.bottom, 5)
        }
        .shadow(color: .black.opacity(0.7), radius: 8, y: 4)
        .accessibilityHidden(true)
    }
}

/// Cropping a clip: its whole frame plays, and the crop (the part that will fill the frame) is
/// drawn over it with the rest dimmed. Drag inside to move it, drag a corner to size it from the
/// opposite corner, or pinch. Each gesture is one undo step, committed on release.
private struct CropFrame: View {
    var model: WorkspaceModel
    var aspect: CGFloat

    private enum Grab {
        case move
        case corner(anchorX: Double, anchorY: Double, right: Bool, bottom: Bool)
    }
    @State private var grab: (kind: Grab, base: Crop)?
    @State private var pinchBase: Crop?

    var body: some View {
        GeometryReader { geo in
            let picture = Viewfinder.pictureRect(aspect: aspect, in: geo.size)
            let crop = model.shownCrop
            let box = CGRect(
                x: picture.minX + crop.x * picture.width, y: picture.minY + crop.y * picture.height,
                width: crop.size * picture.width, height: crop.size * picture.height)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(picture)
                    p.addRect(box)
                }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                Canvas { context, _ in draw(in: &context, box: box) }
                Text(String(format: "%.2f×", crop.magnification))
                    .font(Theme.mono(10, weight: .bold))
                    .foregroundStyle(Theme.obsidian)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.signal))
                    .offset(x: box.minX + 6, y: box.minY + 6)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle().path(in: picture.insetBy(dx: -12, dy: -12)))
            .gesture(dragGesture(picture: picture, box: box))
            .simultaneousGesture(pinchGesture)
        }
        .accessibilityElement()
        .accessibilityLabel("Crop frame")
        .accessibilityValue(String(format: "%.2f times", model.shownCrop.magnification))
        .accessibilityHint("Swipe up to push in, down to pull out.")
        .accessibilityAdjustableAction { direction in
            let crop = model.shownCrop
            model.cropDraft = crop.sized(crop.size * (direction == .increment ? 0.9 : 1 / 0.9))
            model.commitCrop()
        }
    }

    private func draw(in context: inout GraphicsContext, box: CGRect) {
        context.stroke(Path(box), with: .color(Theme.signal), lineWidth: 1.5)
        // Thirds, to place the subject.
        for f in [1.0 / 3, 2.0 / 3] {
            var line = Path()
            line.move(to: CGPoint(x: box.minX + box.width * f, y: box.minY))
            line.addLine(to: CGPoint(x: box.minX + box.width * f, y: box.maxY))
            line.move(to: CGPoint(x: box.minX, y: box.minY + box.height * f))
            line.addLine(to: CGPoint(x: box.maxX, y: box.minY + box.height * f))
            context.stroke(line, with: .color(Theme.ivory.opacity(0.35)), lineWidth: 0.75)
        }
        // Corner handles.
        let arm = min(16, min(box.width, box.height) * 0.3)
        for (x, y, dx, dy) in [
            (box.minX, box.minY, 1.0, 1.0), (box.maxX, box.minY, -1, 1), (box.minX, box.maxY, 1, -1),
            (box.maxX, box.maxY, -1, -1),
        ] {
            var handle = Path()
            handle.move(to: CGPoint(x: x + dx * arm, y: y))
            handle.addLine(to: CGPoint(x: x, y: y))
            handle.addLine(to: CGPoint(x: x, y: y + dy * arm))
            context.stroke(handle, with: .color(Theme.signal), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }

    private func dragGesture(picture: CGRect, box: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                guard picture.width > 0, pinchBase == nil else { return }
                if grab == nil {
                    let base = model.shownCrop
                    let corners = [
                        (CGPoint(x: box.minX, y: box.minY), false, false),
                        (CGPoint(x: box.maxX, y: box.minY), true, false),
                        (CGPoint(x: box.minX, y: box.maxY), false, true),
                        (CGPoint(x: box.maxX, y: box.maxY), true, true),
                    ]
                    let near = corners.min {
                        hypot($0.0.x - g.startLocation.x, $0.0.y - g.startLocation.y)
                            < hypot($1.0.x - g.startLocation.x, $1.0.y - g.startLocation.y)
                    }
                    if let near, hypot(near.0.x - g.startLocation.x, near.0.y - g.startLocation.y) < 30 {
                        // The opposite corner stays put.
                        grab = (
                            .corner(
                                anchorX: near.1 ? base.x : base.x + base.size,
                                anchorY: near.2 ? base.y : base.y + base.size,
                                right: near.1, bottom: near.2), base
                        )
                    } else {
                        grab = (.move, base)
                    }
                }
                guard let grab else { return }
                let fx = Double((g.location.x - picture.minX) / picture.width)
                let fy = Double((g.location.y - picture.minY) / picture.height)
                switch grab.kind {
                case .move:
                    let base = grab.base
                    model.cropDraft = base.centred(
                        at: base.x + base.size / 2 + Double(g.translation.width / picture.width),
                        base.y + base.size / 2 + Double(g.translation.height / picture.height))
                case .corner(let ax, let ay, let right, let bottom):
                    let room = min(right ? 1 - ax : ax, bottom ? 1 - ay : ay)
                    let size = min(max(abs(fx - ax), abs(fy - ay), Crop.minSize), room)
                    model.cropDraft = Crop(x: right ? ax : ax - size, y: bottom ? ay : ay - size, size: size)
                }
            }
            .onEnded { _ in
                grab = nil
                model.commitCrop()
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                let base = pinchBase ?? model.shownCrop
                pinchBase = base
                grab = nil
                model.cropDraft = base.sized(base.size / Double(g.magnification))
            }
            .onEnded { _ in
                pinchBase = nil
                model.commitCrop()
            }
    }
}
