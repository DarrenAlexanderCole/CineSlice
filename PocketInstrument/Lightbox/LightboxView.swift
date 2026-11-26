import EditCore
import SwiftUI

/// LIGHTBOX: the other side of the instrument, revealed by turning the phone sideways. The same
/// project on an illuminated editing table: film strips of the sequence above a fixed divider,
/// sound below, a shared time ruler and playhead, two thumb rollers at the left (scroll and size
/// the video or the audio lanes, chosen by the A/V switch beside them), the backlit counter over
/// the table and a roller under it that jogs and plays the playhead. Beside the table, the
/// monitor runs the full height, as wide as its picture needs but never more than the table's
/// width over 1.2; its key hides it to give the table the whole width. At the far right a column
/// of symbol keys: Done, monitor, undo, redo, Tools and the keys that bring footage, music and
/// sounds onto the table. A long press lifts a clip or a sound to move it freely, leaving gaps.
/// Every edit goes through the workspace model, so turning back upright finds the same project,
/// playhead and selection.
struct LightboxView: View {
    var model: WorkspaceModel
    var state: LightboxState
    var onPreview: () -> Void
    var onDone: () -> Void
    /// Opens Photos (true) or Files (false) for clips that go in at the playhead, on the lowest
    /// video lane with room.
    var onAddClips: (_ photos: Bool) -> Void
    /// Opens Files (false) or a video's sound (true) for the music.
    var onAddMusic: (_ fromVideo: Bool) -> Void
    /// Opens Files (false) or a video's sound (true) for a sound at the playhead.
    var onAddSound: (_ fromVideo: Bool) -> Void

    @State private var panLast: Double?
    @State private var zoomLast: Double?
    /// The instrument inside its margins, and the key column's width, for sizing the monitor.
    @State private var instrumentSize: CGSize = .zero
    @State private var keysWidth: CGFloat = 56
    /// Which side the camera housing is on, when the phone has one: that side keeps clear of it.
    @State private var housing: HorizontalEdge?
    /// The Tools key, and the whole instrument's width, for hanging the tray under the key.
    @State private var toolsKeyFrame: CGRect = .zero
    @State private var bodySize: CGSize = .zero
    @State private var trayHeight: CGFloat = 0
    /// A clip of the sequence or a stacked clip, a sound, or the music, lifted and being moved.
    @State private var videoDrag: LaneDrag?
    @State private var soundDrag: LaneDrag?
    @State private var musicDrag: LaneDrag?

    /// Something lifted by a long press, being moved in time and between lanes.
    private struct LaneDrag: Equatable {
        var clipID: UUID
        /// Seconds from its start to where it was picked up.
        var grab: Double
        /// The finger, in the lanes' coordinates.
        var finger: CGPoint
    }

    static let lanesSpace = "Lightbox.lanes"
    private static let bodySpace = "Lightbox.body"
    /// The table is always at least this much wider than the monitor.
    private static let tableOverMonitor: CGFloat = 1.2
    private static let gutter: CGFloat = 10
    /// The A/V switch's width; the rollers stand beside it, under the bolts.
    private static let switchWidth: CGFloat = 28
    /// Margins from the screen's edges: clear of the camera housing on its side, close elsewhere.
    private static let housingMargin: CGFloat = 54
    private static let edgeMargin: CGFloat = 14

    private static let rulerHeight: CGFloat = 22
    private static let dividerHeight: CGFloat = 4
    private static let columnWidth: CGFloat = 50

    var body: some View {
        HStack(alignment: .top, spacing: Self.gutter) {
            VStack(spacing: 6) {
                header
                HStack(spacing: 6) {
                    sectionSwitch
                    rollerColumn
                    table
                }
                bottomBar
            }
            if state.showsMonitor {
                MonitorScreen(model: model, onFullScreen: onPreview)
                    .frame(width: monitorWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            keyColumn
        }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            instrumentSize = $0
        }
        .padding(.leading, housing == .leading ? Self.housingMargin : Self.edgeMargin)
        .padding(.trailing, housing == .trailing ? Self.housingMargin : Self.edgeMargin)
        .padding(.top, 6)
        // The instrument runs to the screen's sides; only the camera housing is kept clear.
        .ignoresSafeArea(.container, edges: .horizontal)
        .background(LightboxChassis().ignoresSafeArea())
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: { _ in
            housing = Self.housingEdge()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // The interface turns a moment after the device does.
            Task { @MainActor in housing = Self.housingEdge() }
        }
        .coordinateSpace(.named(Self.bodySpace))
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            bodySize = $0
        }
        .overlay { toolsLayer }
        .onAppear {
            model.enterLightbox()
            state.loadWaveforms(model)
        }
        .onChange(of: model.project.sources.count) { state.loadWaveforms(model) }
        .onChange(of: model.project.soundTracks) { state.loadWaveforms(model) }
        .onChange(of: model.selectedSoundID) { _, id in if let id { revealSound(id) } }
        .onChange(of: model.selectedLayerClipID) { _, id in if let id { revealVideoClip(id) } }
        .onChange(of: model.project.referenceAudio?.audioLane) { _, lane in if let lane { revealAudioLane(lane) } }
        .onChange(of: model.engine.currentTime) { old, new in followPlayhead(from: old.seconds, to: new.seconds) }
        .statusBarHidden()
    }

    private var duration: Double { model.project.duration.seconds }
    private var frameRate: Double { Double(model.project.exportSettings.frameRate) }

    // MARK: Header

    /// The bolt stands over the rollers; the A/V switch's corner is left bare, as the screen's
    /// rounded corner takes it. The counter sits at the right, over the table's end.
    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Self.switchWidth - 2)
            Screw(angle: 35).frame(width: Self.columnWidth)
            BrandPlate()
            // The name plate drops its lettering where the table is narrow, keeping the lamp.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Text("LIGHTBOX")
                        .font(Theme.mono(10, weight: .semibold))
                        .tracking(3)
                        .foregroundStyle(Theme.ivory.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize()
                    LED(isOn: true)
                }
                LED(isOn: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("LIGHTBOX")
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            counter.frame(width: 150)
        }
        .frame(height: 40)
    }

    // MARK: Monitor and keys

    /// As wide as the picture at the full height needs, but the table always 1.2 times wider.
    private var monitorWidth: CGFloat {
        let fixed = Self.switchWidth + Self.columnWidth + 12 + keysWidth + Self.gutter * 2
        let shared = max(0, instrumentSize.width - fixed)
        let picture = instrumentSize.height * MonitorScreen.aspect(model) + MonitorScreen.bezel * 2
        return min(picture, shared / (1 + Self.tableOverMonitor)).rounded()
    }

    /// Done at the top, then undo and redo, then Tools and the bring-in keys, all symbols.
    private var keyColumn: some View {
        VStack(spacing: 8) {
            doneKey
            monitorKey
            Spacer(minLength: 4)
            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.instrument(.key, height: 34))
            .disabled(model.undoName == nil)
            .accessibilityLabel(model.undoName.map { "Undo \($0)" } ?? "Undo")
            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward").font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.instrument(.key, height: 34))
            .disabled(model.redoName == nil)
            .accessibilityLabel(model.redoName.map { "Redo \($0)" } ?? "Redo")
            Spacer(minLength: 4)
            toolsKey
            bringInKeys(.vertical)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: true, vertical: false)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            keysWidth = $0
        }
    }

    private var doneKey: some View {
        Button("Done", action: onDone)
            .buttonStyle(.instrument(.prominent, height: 34))
            .accessibilityHint("Turns back to the upright editor.")
    }

    /// Shows the monitor beside the table, or gives the table the whole width.
    private var monitorKey: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { state.showsMonitor.toggle() }
            Haptics.detent()
        } label: {
            Image(systemName: "play.rectangle").font(.system(size: 14, weight: .bold))
        }
        .buttonStyle(.instrument(.key, active: state.showsMonitor, height: 34))
        .accessibilityLabel("Monitor")
        .accessibilityValue(state.showsMonitor ? "Shown" : "Hidden")
        .accessibilityHint("Shows the picture beside the table, or gives the table the whole width.")
    }

    private var toolsKey: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.isToolsOpen.toggle() }
        } label: {
            Image(systemName: "wrench.adjustable.fill").font(.system(size: 14, weight: .bold))
        }
        .buttonStyle(.instrument(.key, active: state.isToolsOpen, height: 34))
        .accessibilityLabel("Tools")
        .accessibilityValue(state.isToolsOpen ? "Open" : "Closed")
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.bodySpace))
        } action: {
            toolsKeyFrame = $0
        }
    }

    private func bringInKeys(_ axis: Axis) -> some View {
        LightboxBringInKeys(
            model: model, axis: axis, onAddClips: onAddClips,
            onAddMusic: onAddMusic, onAddSound: onAddSound)
    }

    private var counter: some View {
        BacklitCounter(time: model.currentTime, duration: model.project.duration, frameRate: frameRate)
    }

    /// Which side of the screen the camera housing is on, when the phone has one and is sideways.
    private static func housingEdge() -> HorizontalEdge? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.windows.first,
            max(window.safeAreaInsets.left, window.safeAreaInsets.right) > 30
        else { return nil }
        switch scene.interfaceOrientation {
        // Home edge on the right: the top of the phone, and its camera, on the left.
        case .landscapeRight: return .leading
        case .landscapeLeft: return .trailing
        default: return nil
        }
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            TimeRuler(viewport: state.viewport) { seconds, ended in scrub(to: seconds, ended: ended) }
                .frame(height: Self.rulerHeight)
            GeometryReader { geo in
                let sectionHeight = (geo.size.height - Self.dividerHeight) / 2
                VStack(spacing: 0) {
                    videoSection.frame(height: sectionHeight)
                    divider
                    audioSection.frame(height: sectionHeight)
                }
                .onAppear { sized(geo.size.width, sectionHeight) }
                .onChange(of: geo.size) { _, size in sized(size.width, (size.height - Self.dividerHeight) / 2) }
            }
        }
        .overlay { playhead }
        .coordinateSpace(.named(Self.lanesSpace))
        .background(lightSurface)
        .simultaneousGesture(panGesture)
        .simultaneousGesture(zoomGesture)
        .metalBezel(cornerRadius: 12, width: 4)
        .onChange(of: videoLanding?.order) { old, new in
            if old != nil, new != nil { Haptics.detent() }
        }
        .onChange(of: videoLanding?.lane) { old, new in
            if old != nil, new != nil { Haptics.detent() }
        }
        .onChange(of: soundLanding?.track) { old, new in
            if old != nil, new != nil { Haptics.detent() }
        }
        .task(id: dragID) { await edgeScrollWhileDragging() }
    }

    /// The glowing ivory surface, faint grid lines at the ruler's labelled marks.
    private var lightSurface: some View {
        ZStack {
            Theme.lightTable
            RadialGradient(
                colors: [Color.white.opacity(0.7), .clear], center: .center, startRadius: 10, endRadius: 420)
            Canvas { context, size in
                let step = state.viewport.rulerStep()
                // From 00:00: the lead-in before it is bare table.
                var t = max(0, (state.viewport.start / step).rounded(.down) * step)
                while state.viewport.x(for: t) < size.width {
                    context.fill(
                        Path(CGRect(x: state.viewport.x(for: t), y: Self.rulerHeight, width: 0.5, height: size.height)),
                        with: .color(Color(hex: 0x8A8268).opacity(0.18)))
                    t += step
                }
            }
        }
        // Shade where the table's rim meets the glass.
        .overlay(Rectangle().strokeBorder(Color.black.opacity(0.3), lineWidth: 8).blur(radius: 6))
        .accessibilityHidden(true)
    }

    /// The fixed line between picture and sound.
    private var divider: some View {
        ZStack {
            Color(hex: 0x3A3A30).opacity(0.75)
            Rectangle().fill(Color.white.opacity(0.4)).frame(height: 1).offset(y: 1.5)
        }
        .frame(height: Self.dividerHeight)
        .accessibilityHidden(true)
    }

    private var videoSection: some View {
        let section = state.viewport.video
        let lane = section.laneHeight
        let pitch = lane + LaneSection.spacing
        return GeometryReader { geo in
            let map = model.sequenceMap
            let landing = videoLanding
            // V1, the sequence, next to the divider; V2 to V10 stack upwards from it.
            let y = geo.size.height - LaneSection.spacing - lane + section.scroll
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.selectInPlace(nil) }
                laneGuides(Project.videoLanes, prefix: "V", height: lane) { y - Double($0) * pitch }
                ForEach(Array(map.entries.enumerated()), id: \.element.clipID) { index, entry in
                    let lifted = videoDrag?.clipID == entry.clipID
                    // While a clip is lifted it follows the finger. Moved along the sequence, the
                    // others stand where they'd be once it's dropped (moved only if it lands on
                    // them); taken to another lane, they stay put.
                    let start =
                        lifted
                        ? landing?.start ?? entry.compositionRange.start.seconds
                        : landing?.starts?[entry.clipID] ?? entry.compositionRange.start.seconds
                    let length = entry.compositionRange.duration.seconds
                    let k = lifted ? landing?.lane ?? 0 : 0
                    if lifted || state.viewport.isVisible(start, start + length, width: state.lanesWidth),
                        let clip = model.project.clip(id: entry.clipID)
                    {
                        let source = model.project.source(for: clip)
                        FilmStripClip(
                            clip: clip, source: source, url: model.mediaURL(for: clip),
                            waveform: source.flatMap { state.waveforms[$0.id] },
                            start: start, viewport: state.viewport, lanesWidth: state.lanesWidth,
                            height: lane, isSelected: model.selectedClipID == clip.id || lifted
                        )
                        .overlay { blockedTint(lifted && landing?.fits == false) }
                        .shadow(color: .black.opacity(lifted ? 0.45 : 0), radius: 8, y: 6)
                        .offset(y: y - Double(k) * pitch - (lifted ? 5 : 0))
                        .zIndex(lifted ? 2 : 0)
                        .animation(
                            lifted ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: landing?.order
                        )
                        .onTapGesture { model.selectInPlace(clip.id) }
                        .modifier(
                            ClipLiftGesture(space: Self.lanesSpace) { phase, point in
                                switch phase {
                                case .began: liftVideoClip(clip.id, start: start, at: point)
                                case .changed: videoDrag?.finger = point
                                case .ended: dropVideoClip(commit: true)
                                case .cancelled: dropVideoClip(commit: false)
                                }
                            }
                        )
                        .accessibilityActions {
                            if index > 0 {
                                Button("Move earlier") { model.move(clip.id, to: index - 1) }
                            }
                            if index < map.entries.count - 1 {
                                Button("Move later") { model.move(clip.id, to: index + 1) }
                            }
                            Button("Move up a lane") {
                                model.moveVideoClip(clip.id, toLane: 1, start: entry.compositionRange.start)
                            }
                        }
                    }
                }
                ForEach(Array(model.project.videoLayers.enumerated()), id: \.element.id) { layer, stacked in
                    ForEach(stacked.clips) { item in
                        layerClip(item, lane: layer + 1, baseY: y, landing: landing)
                    }
                }
                if model.project.clips.isEmpty, model.project.videoLayers.isEmpty {
                    emptyNote("No footage yet · bring some in with Clips")
                }
            }
            .clipped()
        }
    }

    /// Every lane drawn faintly on the table, empty or not, with its name pinned at the left edge.
    private func laneGuides(_ count: Int, prefix: String, height: Double, top: @escaping (Int) -> Double)
        -> some View
    {
        ForEach(0..<count, id: \.self) { k in
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color(hex: 0x8A8268).opacity(0.22), lineWidth: 1)
                )
                .frame(height: height)
                .offset(y: top(k))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .zIndex(-1)
            laneTag("\(prefix)\(k + 1)")
                .offset(x: 3, y: top(k) + 3)
                .zIndex(3)
        }
    }

    private func laneTag(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(7, weight: .heavy))
            .foregroundStyle(Theme.ivory)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.obsidian.opacity(0.75)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Red over something lifted where it can't land.
    @ViewBuilder
    private func blockedTint(_ blocked: Bool) -> some View {
        if blocked {
            RoundedRectangle(cornerRadius: 4).fill(Theme.playhead.opacity(0.35)).allowsHitTesting(false)
        }
    }

    /// A clip stacked on video lane `lane` (V2 and up), `baseY` being V1's top.
    @ViewBuilder
    private func layerClip(_ item: LayerClip, lane: Int, baseY: Double, landing: VideoLanding?) -> some View {
        let lifted = videoDrag?.clipID == item.id
        let start = lifted ? landing?.start ?? item.start.seconds : item.start.seconds
        let length = item.timelineRange.duration.seconds
        let pitch = state.viewport.video.laneHeight + LaneSection.spacing
        let k = lifted ? landing?.lane ?? lane : lane
        if lifted || state.viewport.isVisible(start, start + length, width: state.lanesWidth) {
            FilmStripClip(
                clip: item.clip, source: model.project.source(for: item.clip), url: model.mediaURL(for: item.clip),
                waveform: nil, start: start, viewport: state.viewport, lanesWidth: state.lanesWidth,
                height: state.viewport.video.laneHeight,
                isSelected: model.selectedLayerClipID == item.id || lifted
            )
            .overlay { blockedTint(lifted && landing?.fits == false) }
            .shadow(color: .black.opacity(lifted ? 0.45 : 0.25), radius: lifted ? 8 : 3, y: lifted ? 6 : 2)
            // Lifted, it stands on the lane it would land on.
            .offset(y: baseY - Double(k) * pitch - (lifted ? 5 : 0))
            .zIndex(lifted ? 2 : 1)
            .onTapGesture { model.selectLayerClip(item.id) }
            .modifier(
                ClipLiftGesture(space: Self.lanesSpace) { phase, point in
                    switch phase {
                    case .began: liftVideoClip(item.id, start: item.start.seconds, at: point)
                    case .changed: videoDrag?.finger = point
                    case .ended: dropVideoClip(commit: true)
                    case .cancelled: dropVideoClip(commit: false)
                    }
                }
            )
            .accessibilityLabel("Stacked clip")
            .accessibilityValue("Lane V\(lane + 1)")
            .accessibilityAddTraits(model.selectedLayerClipID == item.id ? [.isSelected] : [])
            .accessibilityActions {
                if lane + 1 < Project.videoLanes {
                    Button("Move up a lane") { model.moveVideoClip(item.id, toLane: lane + 1, start: item.start) }
                }
                Button("Move down a lane") { model.moveVideoClip(item.id, toLane: lane - 1, start: item.start) }
            }
        }
    }

    /// Scrolls the video lanes just enough to show the lane holding clip `id` (clips brought in
    /// can land on a lane above the ones in view).
    private func revealVideoClip(_ id: UUID) {
        guard let lane = model.project.videoLane(ofClip: id) else { return }
        let section = state.viewport.video
        let height = state.videoHeight
        let pitch = section.laneHeight + LaneSection.spacing
        // The lane's top and bottom in the section, lanes stacking up from the divider.
        let top = height - LaneSection.spacing - section.laneHeight - Double(lane) * pitch + section.scroll
        let bottom = top + section.laneHeight
        let delta = top < 0 ? LaneSection.spacing - top : bottom > height ? height - bottom : 0
        guard delta != 0 else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            _ = state.viewport.video.scroll(by: delta, lanes: videoLanes, viewport: height)
        }
    }

    /// The video lane under `y` in the lanes' coordinates: 0 (V1, the sequence) to 9 (V10).
    private func videoLane(atY y: Double) -> Int {
        let section = state.viewport.video
        let fromDivider = Double(Self.rulerHeight) + state.videoHeight - y + section.scroll
        let lane = Int(
            ((fromDivider - LaneSection.spacing / 2) / (section.laneHeight + LaneSection.spacing)).rounded(.down))
        return min(max(lane, 0), Project.videoLanes - 1)
    }

    /// Where a lifted clip would land.
    private struct VideoLanding: Equatable {
        /// Its start, on the frame grid.
        var start: Double
        var lane: Int
        var fits: Bool
        /// Moving along the sequence: where every clip of it would start, and their order.
        var starts: [UUID: Double]?
        var order: [UUID]?
    }

    private var videoLanding: VideoLanding? {
        guard let drag = videoDrag, let from = model.project.videoLane(ofClip: drag.clipID) else { return nil }
        let start = onFrame(state.viewport.seconds(atX: drag.finger.x) - drag.grab)
        let lane = videoLane(atY: drag.finger.y)
        if from == 0, lane == 0 {
            let placed = SequencePlacement(project: model.project).placing(drag.clipID, at: start)
            return VideoLanding(
                start: start.seconds, lane: 0, fits: true,
                starts: Dictionary(uniqueKeysWithValues: placed.map { ($0.clip.id, $0.start.seconds) }),
                order: placed.map(\.clip.id))
        }
        let fits = MoveVideoClipCommand.canMove(drag.clipID, toLane: lane, start: start, in: model.project)
        return VideoLanding(start: start.seconds, lane: lane, fits: fits)
    }

    /// A time on the sequence's frame grid, never before 0.
    private func onFrame(_ seconds: Double) -> MediaTime {
        let rate = Int32(model.project.exportSettings.frameRate)
        return MediaTime(value: Int64(max(0, seconds * Double(rate)).rounded()), timescale: rate)
    }

    private func liftVideoClip(_ clipID: UUID, start: Double, at point: CGPoint) {
        if model.engine.isPlaying { model.engine.pause() }
        if model.project.index(ofClip: clipID) != nil {
            model.selectInPlace(clipID)
        } else {
            model.selectLayerClip(clipID)
        }
        videoDrag = LaneDrag(clipID: clipID, grab: state.viewport.seconds(atX: point.x) - start, finger: point)
        Haptics.press()
    }

    /// One undo step per move, committed on release. Along the sequence it lands where it's
    /// dropped, gaps and all; onto another lane, only where it's clear, else it goes back.
    private func dropVideoClip(commit: Bool) {
        guard let drag = videoDrag else { return }
        if commit, let landing = videoLanding {
            if landing.starts != nil {
                model.place(drag.clipID, at: onFrame(landing.start))
            } else if landing.fits {
                model.moveVideoClip(drag.clipID, toLane: landing.lane, start: onFrame(landing.start))
            } else {
                Haptics.warning()
            }
        }
        videoDrag = nil
    }

    /// Something lifted and being moved: a clip, a sound or the music.
    private var isDragging: Bool { dragID != nil }

    private var dragID: UUID? { videoDrag?.clipID ?? soundDrag?.clipID ?? musicDrag?.clipID }

    /// A lifted clip, sound or song held near either end of the lanes pans the table that way,
    /// faster the closer; held near the top or bottom of its section, it scrolls the lanes.
    private func edgeScrollWhileDragging() async {
        let edge = 44.0
        while !Task.isCancelled, let finger = (videoDrag ?? soundDrag ?? musicDrag)?.finger {
            let width = state.lanesWidth
            let x = Double(finger.x)
            if x < edge {
                state.viewport.pan(by: (edge - x) * 0.25, duration: duration, width: width)
            } else if x > width - edge {
                state.viewport.pan(by: -(x - (width - edge)) * 0.25, duration: duration, width: width)
            }
            if videoDrag != nil {
                let y = Double(finger.y) - Double(Self.rulerHeight)
                let height = state.videoHeight
                // Lanes stack upwards: near the top shows higher ones.
                if y < 24 {
                    state.viewport.video.scroll(by: 4, lanes: videoLanes, viewport: height)
                } else if y > height - 24 {
                    state.viewport.video.scroll(by: -4, lanes: videoLanes, viewport: height)
                }
            } else {
                let y = Double(finger.y) - audioTop
                let height = state.audioHeight
                if y > height - 24 {
                    state.viewport.audio.scroll(by: 4, lanes: audioLanes, viewport: height)
                } else if y < 24 {
                    state.viewport.audio.scroll(by: -4, lanes: audioLanes, viewport: height)
                }
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// The ten audio lanes, the music on whichever one it sits on and the sounds on theirs.
    private var audioSection: some View {
        let section = state.viewport.audio
        let landing = soundLanding
        return GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.selectInPlace(nil) }
                laneGuides(Project.maxSoundTracks, prefix: "A", height: section.laneHeight) { laneY($0) }
                if let music = model.project.referenceAudio {
                    let moving = musicLanding
                    let shown = moving?.music ?? music
                    if moving != nil
                        || state.viewport.isVisible(
                            shown.timelineRange.start.seconds, shown.timelineRange.end.seconds,
                            width: state.lanesWidth)
                    {
                        AudioGlassClip(
                            music: shown, sequenceEnd: model.project.duration.seconds, waveform: model.waveform,
                            viewport: state.viewport, lanesWidth: state.lanesWidth, height: section.laneHeight,
                            isLifted: moving != nil
                        )
                        .overlay { blockedTint(moving?.fits == false) }
                        .shadow(color: .black.opacity(moving == nil ? 0 : 0.4), radius: 8, y: 6)
                        .offset(y: laneY(shown.audioLane) - (moving == nil ? 0 : 4))
                        .zIndex(moving == nil ? 0 : 2)
                        .modifier(
                            ClipLiftGesture(space: Self.lanesSpace) { phase, point in
                                switch phase {
                                case .began: liftMusic(at: point)
                                case .changed: musicDrag?.finger = point
                                case .ended: dropMusic(commit: true)
                                case .cancelled: dropMusic(commit: false)
                                }
                            }
                        )
                        .accessibilityAction(named: "Move earlier by a beat") {
                            model.nudgeMusic(by: MediaTime(seconds: -0.5))
                        }
                        .accessibilityAction(named: "Move later by a beat") {
                            model.nudgeMusic(by: MediaTime(seconds: 0.5))
                        }
                        .accessibilityAction(named: "Move down a lane") {
                            model.placeMusic(lane: music.audioLane + 1, offset: music.offset)
                        }
                    }
                }
                ForEach(Array(model.project.soundTracks.enumerated()), id: \.element.id) { track, lane in
                    ForEach(lane.clips) { clip in
                        soundClip(clip, track: track, lane: lane, landing: landing)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    @ViewBuilder
    private func soundClip(
        _ clip: SoundClip, track: Int, lane: SoundTrack,
        landing: (start: Double, track: Int, fits: Bool)?
    ) -> some View {
        let lifted = soundDrag?.clipID == clip.id
        let start = lifted ? landing?.start ?? clip.start.seconds : clip.start.seconds
        let length = clip.sourceRange.duration.seconds
        if lifted || state.viewport.isVisible(start, start + length, width: state.lanesWidth) {
            SoundGlassClip(
                clip: clip, waveform: state.soundWaveforms[clip.fileName], start: start, viewport: state.viewport,
                lanesWidth: state.lanesWidth, height: state.viewport.audio.laneHeight,
                isSelected: model.selectedSoundID == clip.id || lifted, isBlocked: lifted && landing?.fits == false,
                isMuted: lane.isMuted
            )
            .shadow(color: .black.opacity(lifted ? 0.4 : 0), radius: 8, y: 6)
            // Lifted, it stands on the lane it would land on.
            .offset(y: laneY(lifted ? landing?.track ?? track : track) - (lifted ? 4 : 0))
            .zIndex(lifted ? 2 : 1)
            .onTapGesture { model.selectSound(clip.id) }
            .modifier(
                ClipLiftGesture(space: Self.lanesSpace) { phase, point in
                    switch phase {
                    case .began: liftSound(clip, at: point)
                    case .changed: soundDrag?.finger = point
                    case .ended: dropSound(commit: true)
                    case .cancelled: dropSound(commit: false)
                    }
                }
            )
            .accessibilityActions {
                if track > 0 {
                    Button("Move up a lane") { model.moveSound(clip.id, toTrack: track - 1, start: clip.start) }
                }
                if track + 1 < Project.maxSoundTracks {
                    Button("Move down a lane") { model.moveSound(clip.id, toTrack: track + 1, start: clip.start) }
                }
            }
        }
    }

    /// While the music is lifted: the song where it would land (its start on the frame grid, kept
    /// overlapping the sequence, on the lane under the finger), and whether it's clear there.
    private var musicLanding: (music: AudioTrack, fits: Bool)? {
        guard let drag = musicDrag, var music = model.project.referenceAudio else { return nil }
        let wanted = state.viewport.seconds(atX: drag.finger.x) - drag.grab
        let rate = Int32(model.project.exportSettings.frameRate)
        let framed = MediaTime(value: Int64((wanted * Double(rate)).rounded()), timescale: rate)
        music.offset = music.clampedOffset(framed, sequenceDuration: model.project.duration)
        music.lane = audioLane(atY: drag.finger.y)
        let fits = model.project.audioLaneFits(music.timelineRange, lane: music.audioLane, excludingMusic: true)
        return (music, fits)
    }

    /// A locked song doesn't lift: a warning tap instead.
    private func liftMusic(at point: CGPoint) {
        guard let music = model.project.referenceAudio else { return }
        guard !music.isLocked else {
            Haptics.warning()
            return
        }
        if model.engine.isPlaying { model.engine.pause() }
        musicDrag = LaneDrag(
            clipID: music.id, grab: state.viewport.seconds(atX: point.x) - music.offset.seconds, finger: point)
        Haptics.press()
    }

    /// One undo step per move, committed on release; where a sound is in the way, it goes back.
    private func dropMusic(commit: Bool) {
        guard musicDrag != nil else { return }
        if commit, let landing = musicLanding, let current = model.project.referenceAudio,
            landing.music.offset != current.offset || landing.music.audioLane != current.audioLane
        {
            if landing.fits {
                model.placeMusic(lane: landing.music.audioLane, offset: landing.music.offset)
            } else {
                Haptics.warning()
            }
        }
        musicDrag = nil
    }

    /// The top of audio lane `k` in the section.
    private func laneY(_ k: Int) -> Double {
        let section = state.viewport.audio
        return LaneSection.spacing + Double(k) * (section.laneHeight + LaneSection.spacing) - section.scroll
    }

    /// Scrolls the audio lanes just enough to show the lane holding sound `id` (a sound just
    /// brought in can land on a lane below the ones in view).
    private func revealSound(_ id: UUID) {
        guard let track = model.project.soundLocation(id: id)?.track else { return }
        revealAudioLane(track)
    }

    private func revealAudioLane(_ lane: Int) {
        let section = state.viewport.audio
        let top = laneY(lane)
        let bottom = top + section.laneHeight + LaneSection.spacing
        let height = state.audioHeight
        let delta = top < 0 ? top - LaneSection.spacing : bottom > height ? bottom - height : 0
        guard delta != 0 else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            _ = state.viewport.audio.scroll(by: delta, lanes: audioLanes, viewport: height)
        }
    }

    /// The audio section's top in the lanes' coordinates.
    private var audioTop: Double { Double(Self.rulerHeight) + state.videoHeight + Double(Self.dividerHeight) }

    /// The audio lane under `y` in the lanes' coordinates: 0 (A1) to 9 (A10).
    private func audioLane(atY y: Double) -> Int {
        let section = state.viewport.audio
        let contentY = y - audioTop + section.scroll
        let lane = Int(
            ((contentY - LaneSection.spacing / 2) / (section.laneHeight + LaneSection.spacing)).rounded(.down))
        return min(max(lane, 0), Project.maxSoundTracks - 1)
    }

    /// Where a lifted sound would land: its start (on the frame grid), its lane, and whether it
    /// fits there.
    private var soundLanding: (start: Double, track: Int, fits: Bool)? {
        guard let drag = soundDrag, let clip = model.project.sound(id: drag.clipID) else { return nil }
        let start = onFrame(state.viewport.seconds(atX: drag.finger.x) - drag.grab)
        let track = audioLane(atY: drag.finger.y)
        let range = MediaTimeRange(start: start, duration: clip.sourceRange.duration)
        return (start.seconds, track, model.project.soundFits(range, onTrack: track, excluding: clip.id))
    }

    private func liftSound(_ clip: SoundClip, at point: CGPoint) {
        if model.engine.isPlaying { model.engine.pause() }
        model.selectSound(clip.id)
        soundDrag = LaneDrag(
            clipID: clip.id, grab: state.viewport.seconds(atX: point.x) - clip.start.seconds, finger: point)
        Haptics.press()
    }

    /// One undo step per move, committed on release; where it would overlap, it goes back.
    private func dropSound(commit: Bool) {
        guard let drag = soundDrag else { return }
        if commit, let landing = soundLanding {
            if landing.fits {
                model.moveSound(drag.clipID, toTrack: landing.track, start: onFrame(landing.start))
            } else {
                Haptics.warning()
            }
        }
        soundDrag = nil
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.mono(9, weight: .semibold))
            .tracking(1)
            .foregroundStyle(Color(hex: 0x6E6852).opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    /// Orange-red, from the ruler through both sections, a pointer on the ruler.
    private var playhead: some View {
        GeometryReader { geo in
            let x = state.viewport.x(for: model.currentTime.seconds)
            if x >= -2, x <= geo.size.width + 2 {
                ZStack(alignment: .top) {
                    Rectangle().fill(Theme.playhead).frame(width: 2)
                        .shadow(color: Theme.playhead.opacity(0.5), radius: 2)
                    Triangle().fill(Theme.playhead).frame(width: 12, height: 8).offset(y: Self.rulerHeight - 9)
                }
                .frame(width: 12)
                .offset(x: x - 6)
                .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Gestures

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { g in
                // A drag that starts mostly vertical is left alone: lanes scroll on the rollers.
                // On the ruler it scrubs instead.
                guard !isDragging else { return }
                if panLast == nil,
                    abs(g.translation.height) > abs(g.translation.width) || g.startLocation.y < Self.rulerHeight
                {
                    return
                }
                let dx = g.translation.width - (panLast ?? 0)
                panLast = g.translation.width
                state.viewport.pan(by: dx, duration: duration, width: state.lanesWidth)
            }
            .onEnded { _ in panLast = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                guard !isDragging else { return }
                let factor = g.magnification / (zoomLast ?? 1)
                zoomLast = g.magnification
                state.viewport.zoom(
                    by: factor, anchorX: g.startLocation.x, duration: duration, width: state.lanesWidth)
            }
            .onEnded { _ in zoomLast = nil }
    }

    private func scrub(to seconds: Double, ended: Bool) {
        // Like the roller: scrubbing pauses, and it stays paused.
        if model.engine.isPlaying { model.engine.pause() }
        model.scrub(to: MediaTime(seconds: min(max(seconds, 0), duration)), precise: ended)
    }

    /// While the playhead was on screen, keep it there as it moves (playback or the roller). A
    /// playhead panned out of view is left alone until it comes back.
    private func followPlayhead(from old: Double, to new: Double) {
        let width = state.lanesWidth
        guard width > 0, panLast == nil, zoomLast == nil, !isDragging else { return }
        let oldX = state.viewport.x(for: old)
        guard oldX >= -4, oldX <= width + 4 else { return }
        state.viewport.follow(new, width: width, duration: duration)
    }

    private func sized(_ width: CGFloat, _ height: CGFloat) {
        let width = Double(width)
        let sectionHeight = Double(height)
        state.lanesWidth = width
        state.videoHeight = sectionHeight
        state.audioHeight = sectionHeight
        if !state.hasFitted, duration > 0, width > 0 {
            state.viewport.fit(duration: duration, width: width)
            state.hasFitted = true
        }
        state.viewport.video.clamp(lanes: videoLanes, viewport: sectionHeight)
        state.viewport.audio.clamp(lanes: audioLanes, viewport: sectionHeight)
    }

    // MARK: Rollers

    /// Every lane is always there, empty or not: ten for picture (the sequence and nine stacked
    /// above it) and ten for sound.
    private var videoLanes: Int { Project.videoLanes }
    private var audioLanes: Int { Project.maxSoundTracks }

    /// The A/V switch: a small slider set into the chassis. Its aluminium thumb sits at V or A,
    /// the letter lit, choosing which lanes the two rollers work. A tap moves it over.
    private var sectionSwitch: some View {
        let video = state.rollersOnVideo
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { state.rollersOnVideo.toggle() }
            Haptics.detent()
        } label: {
            ZStack(alignment: video ? .top : .bottom) {
                VStack {
                    switchLetter("V", lit: false)
                    Spacer()
                    switchLetter("A", lit: false)
                }
                .padding(.vertical, 12)
                .opacity(0.5)
                switchThumb(video ? "V" : "A")
            }
            .padding(3)
            .frame(width: 28, height: 112)
            .recessed(cornerRadius: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Self.rulerHeight)
        .accessibilityLabel("Roller lanes")
        .accessibilityValue(video ? "Video" : "Audio")
        .accessibilityHint("Switches the scroll and size rollers between the video and the audio lanes.")
    }

    private func switchThumb(_ letter: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(spacing: 4) {
            Circle()
                .fill(Theme.signal)
                .frame(width: 4, height: 4)
                .shadow(color: Theme.signal.opacity(0.9), radius: 3)
            switchLetter(letter, lit: true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(
            shape.fill(
                LinearGradient(
                    colors: [Color(hex: 0xD9DACE), Theme.aluminum, Color(hex: 0x8E9185)], startPoint: .top,
                    endPoint: .bottom))
        )
        .overlay(BrushedMetal(strength: 1).clipShape(shape).blendMode(.multiply).allowsHitTesting(false))
        .overlay(shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1.5)
    }

    private func switchLetter(_ letter: String, lit: Bool) -> some View {
        Text(letter)
            .font(Theme.mono(12, weight: .heavy))
            .foregroundStyle(lit ? Theme.obsidian : Theme.secondaryLabel)
    }

    /// Scroll above, size below, for whichever lanes the switch has chosen.
    private var rollerColumn: some View {
        let video = state.rollersOnVideo
        return VStack(spacing: 0) {
            columnLabel("SCROLL").frame(height: Self.rulerHeight)
            roller(video: video, scroll: true)
                .padding(.vertical, 5)
            columnLabel("SIZE").frame(height: 14)
            roller(video: video, scroll: false)
                .padding(.vertical, 5)
        }
        // A fresh roller for the other lanes, so a coast never carries across.
        .id(video)
        .frame(width: Self.columnWidth)
    }

    private func columnLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(7, weight: .heavy))
            .tracking(1)
            .foregroundStyle(Theme.aluminum.opacity(0.85))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func roller(video: Bool, scroll: Bool) -> some View {
        let section = video ? state.viewport.video : state.viewport.audio
        let lanes = video ? videoLanes : audioLanes
        let height = video ? state.videoHeight : state.audioHeight
        let which = video ? "Video" : "Audio"
        if scroll {
            let maxScroll = section.maxScroll(lanes: lanes, viewport: height)
            ThumbRoller(
                label: "\(which) lane scroll",
                value: maxScroll > 0 ? "\(Int(section.scroll / maxScroll * 100)) percent" : "Nothing to scroll",
                position: maxScroll > 0 ? (video ? 1 - section.scroll / maxScroll : section.scroll / maxScroll) : nil,
                slotOnLeading: false
            ) { dy in
                // The lanes follow the drum's surface: video lanes stack upwards, audio lanes downwards.
                let delta = video ? dy : -dy
                let used =
                    video
                    ? state.viewport.video.scroll(by: delta, lanes: lanes, viewport: height)
                    : state.viewport.audio.scroll(by: delta, lanes: lanes, viewport: height)
                return video ? used : -used
            }
        } else {
            let range = section.range
            ThumbRoller(
                label: "\(which) lane height",
                value: "\(Int(section.laneHeight)) points",
                position: 1 - (section.laneHeight - range.lowerBound) / (range.upperBound - range.lowerBound),
                slotOnLeading: false,
                onTurn: { dy in
                    // Up makes lanes taller. Half speed: a lane's height is a finer thing than a scroll.
                    let delta = -dy * 0.5
                    let used =
                        video
                        ? state.viewport.video.resize(by: delta, lanes: lanes, viewport: height)
                        : state.viewport.audio.resize(by: delta, lanes: lanes, viewport: height)
                    return -used * 2
                },
                coasts: false
            )
        }
    }

    // MARK: Bottom

    /// The transport under the table, its bolt under the rollers like the header's: the cut keys
    /// and play at the left, the jog roller filling the space to fit at the right.
    private var bottomBar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Self.switchWidth - 4)
            Screw(angle: -20).frame(width: Self.columnWidth)
            HStack(spacing: 8) {
                Button {
                    model.jumpToCut(forward: false)
                } label: {
                    Image(systemName: "backward.end.fill").font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.instrument(.key, height: 40))
                .accessibilityLabel("Previous cut")
                Button {
                    model.engine.togglePlay()
                } label: {
                    Image(systemName: model.engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 30)
                }
                .buttonStyle(.instrument(.dark, active: model.engine.isPlaying, height: 40))
                .disabled(model.project.clips.isEmpty)
                .accessibilityLabel(model.engine.isPlaying ? "Pause" : "Play")
                Button {
                    model.jumpToCut(forward: true)
                } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 14, weight: .bold))
                }
                .buttonStyle(.instrument(.key, height: 40))
                .accessibilityLabel("Next cut")
            }
            .fixedSize()
            JogRoller(model: model)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .disabled(model.project.clips.isEmpty)
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    state.viewport.fit(duration: duration, width: state.lanesWidth)
                }
                Haptics.detent()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .bold))
            }
            .buttonStyle(.instrument(.key, height: 40))
            .accessibilityLabel("Fit whole project")
        }
        .frame(height: 56)
    }

    // MARK: Tools

    private var toolsLayer: some View {
        ZStack(alignment: .topTrailing) {
            // Taps outside the tray close it, and never reach the table underneath. Always here,
            // taking taps only while the tray is open, so it can't linger as the tray animates away.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .allowsHitTesting(state.isToolsOpen)
                .onTapGesture { closeTools() }
                .accessibilityHidden(!state.isToolsOpen)
                .accessibilityAction(named: "Close tools") { closeTools() }
            if state.isToolsOpen {
                // Out to the left of the Tools key, level with it.
                // Raised as far as it must be to stay on screen when a panel opens under its keys.
                ToolDrawer(model: model)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        trayHeight = $0
                    }
                    .padding(.top, max(0, min(toolsKeyFrame.minY - 6, bodySize.height - trayHeight - 8)))
                    .padding(.trailing, max(0, bodySize.width - toolsKeyFrame.minX + 8))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func closeTools() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { state.isToolsOpen = false }
    }
}

/// The CS brass badge and the italic Cine/Slice wordmark with its Signal slash.
struct BrandPlate: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("CS")
                .font(.system(size: 12, weight: .heavy, design: .serif))
                .foregroundStyle(Color(hex: 0x2A2416))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4).fill(
                        LinearGradient(
                            colors: [Color(hex: 0xD8C08A), Theme.brass, Color(hex: 0x8A7246)], startPoint: .top,
                            endPoint: .bottom))
                )
            Rectangle().fill(Theme.ivory.opacity(0.35)).frame(width: 1, height: 22)
            (Text("Cine") + Text("/").foregroundColor(Theme.signal) + Text("Slice"))
                .font(.system(size: 22, weight: .semibold, design: .serif).italic())
                .foregroundStyle(Theme.ivory)
                .shadow(color: .black.opacity(0.6), radius: 0, y: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("CineSlice")
    }
}

/// The landscape body: the same olive brushed graphite as the upright chassis, all round.
struct LightboxChassis: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x4B5539), Color(hex: 0x3A4230), Color(hex: 0x262B1F)], startPoint: .top,
                endPoint: .bottom)
            BrushedMetal(strength: 0.8)
            Grain(opacity: 0.5)
        }
        .accessibilityHidden(true)
    }
}
