import EditCore
import SwiftUI

/// Arrange state: the whole sequence as tiles. Tap selects (and cues the
/// playhead), long-press then drag reorders; the Explore state opens the
/// selected clip. Reorder and trim never share a gesture: trimming lives in Explore.
/// Under the tiles, the sequence lane shows the music waveform, cuts and loop bracket.
struct ArrangeDeck: View {
    var model: WorkspaceModel
    var onAddPhotos: () -> Void
    var onAddFiles: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ClipStrip(model: model, onAddPhotos: onAddPhotos, onAddFiles: onAddFiles)
            SequenceLane(model: model)
            selectedClipBar
            JogDial(title: "JOG", onStep: { model.jog(by: $0) }, onShuttle: { model.shuttle($0) })
                .disabled(model.project.clips.isEmpty)
            TransportRow(model: model) {
                Color.clear.frame(width: 44, height: 44)
            } trailing: {
                LoopButton(model: model)
            }
        }
    }

    @ViewBuilder
    private var selectedClipBar: some View {
        if let clip = model.selectedClip {
            let source = model.project.source(for: clip)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source?.originalFilename ?? "Clip \((model.project.index(ofClip: clip.id) ?? 0) + 1)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(
                        "\(String(format: "%.2fs", clip.compositionDuration.seconds)) · \(source?.orientationLabel ?? "Missing") · \(clip.framing == .fill ? "Fill" : "Fit")"
                    )
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    model.toggleFraming(clip.id)
                } label: {
                    Image(
                        systemName: clip.framing == .fill
                            ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.instrument())
                .accessibilityLabel(
                    clip.framing == .fill ? "Framing: fill. Switch to fit" : "Framing: fit. Switch to fill")

                Button {
                    model.duplicate(clip.id)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.instrument())
                .accessibilityLabel("Duplicate clip")

                Button(role: .destructive) {
                    model.remove(clip.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.instrument())
                .accessibilityLabel("Remove clip from sequence")
            }
        } else {
            Text("Select a clip to explore and trim it")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

/// Horizontal clip tiles. A swipe scrolls; long-press then drag reorders, auto-scrolling
/// when the dragged tile nears either edge. The selected clip, and the clip under the
/// playhead while playing, are kept in view.
struct ClipStrip: View {
    var model: WorkspaceModel
    var onAddPhotos: () -> Void
    var onAddFiles: () -> Void

    private let tileWidth: CGFloat = 64
    private let spacing: CGFloat = 8
    private let inset: CGFloat = 2
    private var stride: CGFloat { tileWidth + spacing }
    /// Distance from either edge of the strip at which a reorder drag starts auto-scrolling.
    private let edgeZone: CGFloat = 44
    fileprivate static let viewport = "ClipStrip.viewport"

    /// A reorder in progress. Only exists after the long press completes, and is cleared when
    /// the press ends, fails or is cancelled, so scrolling can never stay locked.
    private struct Reorder: Equatable {
        var clipID: UUID
        /// Scroll offset when the drag began; auto-scroll adds to the finger's travel.
        var startScrollOffset: CGFloat
        var startX: CGFloat
        var fingerX: CGFloat
    }

    @State private var reorder: Reorder?
    /// iOS 17 fallback: true while a SwiftUI reorder gesture is live; resets on cancel.
    @GestureState private var isPressing = false
    @State private var scrollOffset: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { index, clip in
                        tile(clip, index: index)
                    }
                    addMenu
                }
                .padding(.vertical, 6)
                .padding(.horizontal, inset)
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named(Self.viewport)).minX
                } action: {
                    scrollOffset = -$0
                }
            }
            .coordinateSpace(.named(Self.viewport))
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                viewportWidth = $0
            }
            .scrollDisabled(reorder != nil)
            .onChange(of: reorder?.clipID) { _, id in
                if id != nil { Haptics.press() }
            }
            .onChange(of: proposedIndex) { old, index in
                if old != nil, index != nil { Haptics.detent() }
            }
            .onChange(of: isPressing) { _, pressing in
                // A cancelled SwiftUI gesture never calls onEnded; a completed one has already
                // committed by the time this runs.
                if !pressing { Task { endReorder(commit: false) } }
            }
            .onChange(of: model.selectedClipID) { _, id in
                guard let id, reorder == nil else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id) }
            }
            .onChange(of: model.clipUnderPlayhead) { _, id in
                guard let id, model.engine.isPlaying, reorder == nil else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id) }
            }
            .task(id: reorder?.clipID) {
                guard reorder != nil else { return }
                while !Task.isCancelled {
                    autoScroll(proxy)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
        .frame(height: 112)
    }

    /// Horizontal travel of the dragged tile in content space.
    private var dragOffset: CGFloat {
        guard let reorder else { return 0 }
        return reorder.fingerX - reorder.startX + scrollOffset - reorder.startScrollOffset
    }

    private var proposedIndex: Int? {
        guard let id = reorder?.clipID, let from = model.project.index(ofClip: id) else { return nil }
        let shift = Int((dragOffset / stride).rounded())
        return min(max(from + shift, 0), model.project.clips.count - 1)
    }

    /// How far a non-dragged tile slides to make room.
    private func makeRoomOffset(for index: Int) -> CGFloat {
        guard let id = reorder?.clipID, let from = model.project.index(ofClip: id), let to = proposedIndex else {
            return 0
        }
        if from < to, index > from, index <= to { return -stride }
        if to < from, index >= to, index < from { return stride }
        return 0
    }

    /// While the finger is in an edge zone, reveals one more tile in that direction.
    private func autoScroll(_ proxy: ScrollViewProxy) {
        guard let fingerX = reorder?.fingerX else { return }
        let clips = model.project.clips
        if fingerX < edgeZone {
            // The last tile whose leading edge is hidden past the left edge.
            let i = Int(((scrollOffset - inset - 0.5) / stride).rounded(.up)) - 1
            guard clips.indices.contains(i) else { return }
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(clips[i].id, anchor: .leading) }
        } else if fingerX > viewportWidth - edgeZone {
            // The first tile whose trailing edge is hidden past the right edge.
            let i = Int(((scrollOffset + viewportWidth + 0.5 - inset - tileWidth) / stride).rounded(.down)) + 1
            guard clips.indices.contains(i) else { return }
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(clips[i].id, anchor: .trailing) }
        }
    }

    private func tile(_ clip: TimelineClip, index: Int) -> some View {
        let isSelected = clip.id == model.selectedClipID
        let isPlaying = clip.id == model.clipUnderPlayhead && model.mode == .arrange
        let isDragging = clip.id == reorder?.clipID
        let url = model.mediaURL(for: clip)
        let midpoint = clip.sourceRange.start + MediaTime(seconds: clip.sourceRange.duration.seconds / 2)
        let lastIndex = model.project.clips.count - 1

        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                VideoFrameView(url: url, time: midpoint.cmTime, maxPixel: 180)
                    .frame(width: tileWidth, height: 84)
                Text(String(format: "%.1fs", clip.compositionDuration.seconds))
                    .font(Theme.mono(9))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Theme.signal : Theme.hairline, lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: isSelected ? Theme.signal.opacity(0.45) : .black.opacity(0.4), radius: isSelected ? 8 : 3)
            HStack(spacing: 4) {
                LED(isOn: isPlaying)
                Text(String(format: "%02d", index + 1))
                    .font(Theme.caption)
                    .foregroundStyle(isSelected ? Theme.signal : Theme.secondaryLabel)
            }
        }
        .scaleEffect(isDragging ? 1.08 : 1)
        .zIndex(isDragging ? 1 : 0)
        .offset(x: isDragging ? dragOffset : makeRoomOffset(for: index))
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: proposedIndex)
        .contentShape(Rectangle())
        .onTapGesture { model.select(clip.id) }
        .modifier(ReorderGestureModifier(clip: clip, strip: self))
        .id(clip.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip \(index + 1), \(String(format: "%.1f", clip.compositionDuration.seconds)) seconds")
        .accessibilityAddTraits(
            isSelected ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton
        )
        .accessibilityAction { model.select(clip.id) }
        .accessibilityAction(named: "Trim") { model.enterExplore(clip.id) }
        .accessibilityActions {
            if index > 0 {
                Button("Move left") { model.move(clip.id, to: index - 1) }
            }
            if index < lastIndex {
                Button("Move right") { model.move(clip.id, to: index + 1) }
            }
        }
    }

    private func beginReorder(_ clipID: UUID, at x: CGFloat) {
        reorder = Reorder(clipID: clipID, startScrollOffset: scrollOffset, startX: x, fingerX: x)
    }

    private func moveReorder(to x: CGFloat) {
        reorder?.fingerX = x
    }

    /// One undo step per drag: the move is committed only on release.
    private func endReorder(commit: Bool) {
        guard let current = reorder else { return }
        if commit, let to = proposedIndex, to != model.project.index(ofClip: current.clipID) {
            model.move(current.clipID, to: to)
        }
        reorder = nil
    }

    /// Long-press then drag. On iOS 18+ this is a UIKit long press, which yields to the
    /// scroll view's pan when the finger moves first; SwiftUI's sequenced long-press/drag
    /// claims the touch there and stops the strip scrolling.
    private struct ReorderGestureModifier: ViewModifier {
        let clip: TimelineClip
        let strip: ClipStrip

        func body(content: Content) -> some View {
            if #available(iOS 18.0, *) {
                content.gesture(
                    ReorderPress { phase, x in
                        switch phase {
                        case .began: strip.beginReorder(clip.id, at: x)
                        case .changed: strip.moveReorder(to: x)
                        case .ended: strip.endReorder(commit: true)
                        case .cancelled: strip.endReorder(commit: false)
                        }
                    })
            } else {
                content.gesture(legacyGesture)
            }
        }

        /// `.first` only means the finger is down; the reorder starts at `.second`, once the
        /// long press has completed.
        private var legacyGesture: some Gesture {
            LongPressGesture(minimumDuration: ClipStrip.pressDuration)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(ClipStrip.viewport)))
                .updating(strip.$isPressing) { _, state, _ in state = true }
                .onChanged { value in
                    guard case .second(true, let drag?) = value else { return }
                    if strip.reorder == nil { strip.beginReorder(clip.id, at: drag.startLocation.x) }
                    strip.moveReorder(to: drag.location.x)
                }
                .onEnded { _ in strip.endReorder(commit: true) }
        }
    }

    static let pressDuration = 0.3

    private var addMenu: some View {
        Menu {
            Button {
                onAddPhotos()
            } label: {
                Label("From Photos", systemImage: "photo.on.rectangle")
            }
            Button {
                onAddFiles()
            } label: {
                Label("From Files", systemImage: "folder")
            }
            Button {
                Task { await model.addDemoClips() }
            } label: {
                Label("Demo clips", systemImage: "film.stack")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.ivory)
                .frame(width: tileWidth, height: 84)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.ivory.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
        .accessibilityLabel("Add clips")
        .padding(.bottom, 18)
    }
}

/// A UIKit long press reporting the finger's x in the clip strip's viewport.
@available(iOS 18.0, *)
private struct ReorderPress: UIGestureRecognizerRepresentable {
    enum Phase { case began, changed, ended, cancelled }
    var action: (Phase, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = ClipStrip.pressDuration
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let x = context.converter.location(in: .named(ClipStrip.viewport)).x
        switch recognizer.state {
        case .began: action(.began, x)
        case .changed: action(.changed, x)
        case .ended: action(.ended, x)
        case .cancelled, .failed: action(.cancelled, x)
        default: break
        }
    }
}
