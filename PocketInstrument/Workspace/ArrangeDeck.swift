import EditCore
import SwiftUI

/// Arrange state: the whole sequence as tiles. Tap selects (and cues the
/// playhead), long-press then drag reorders, "Explore" opens the clip. Reorder and trim never share a gesture: trimming lives in Explore.
struct ArrangeDeck: View {
    var model: WorkspaceModel
    var onAddPhotos: () -> Void
    var onAddFiles: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ClipStrip(model: model, onAddPhotos: onAddPhotos, onAddFiles: onAddFiles)
            selectedClipBar
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

                Button("Explore") { model.enterExplore(clip.id) }
                    .buttonStyle(.instrument(.key))
            }
        } else {
            Text("Select a clip to explore and trim it")
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }
}

/// Horizontal clip tiles with long-press-drag reordering.
struct ClipStrip: View {
    var model: WorkspaceModel
    var onAddPhotos: () -> Void
    var onAddFiles: () -> Void

    private let tileWidth: CGFloat = 64
    private let spacing: CGFloat = 8
    private var stride: CGFloat { tileWidth + spacing }

    @State private var draggingID: UUID?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                ForEach(Array(model.project.clips.enumerated()), id: \.element.id) { index, clip in
                    tile(clip, index: index)
                }
                addMenu
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .scrollDisabled(draggingID != nil)
        .frame(height: 112)
    }

    private var proposedIndex: Int? {
        guard let id = draggingID, let from = model.project.index(ofClip: id) else { return nil }
        let shift = Int((dragOffset / stride).rounded())
        return min(max(from + shift, 0), model.project.clips.count - 1)
    }

    /// How far a non-dragged tile slides to make room.
    private func makeRoomOffset(for index: Int) -> CGFloat {
        guard let id = draggingID, let from = model.project.index(ofClip: id), let to = proposedIndex else { return 0 }
        if from < to, index > from, index <= to { return -stride }
        if to < from, index >= to, index < from { return stride }
        return 0
    }

    private func tile(_ clip: TimelineClip, index: Int) -> some View {
        let isSelected = clip.id == model.selectedClipID
        let isPlaying = clip.id == model.clipUnderPlayhead && model.mode == .arrange
        let isDragging = clip.id == draggingID
        let url = model.mediaURL(for: clip)
        let midpoint = clip.sourceRange.start + MediaTime(seconds: clip.sourceRange.duration.seconds / 2)

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
        .gesture(reorderGesture(for: clip))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip \(index + 1), \(String(format: "%.1f", clip.compositionDuration.seconds)) seconds")
        .accessibilityAddTraits(
            isSelected ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton
        )
        .accessibilityAction { model.select(clip.id) }
        .accessibilityAction(named: "Explore") { model.enterExplore(clip.id) }
        .accessibilityAction(named: "Move left") { model.move(clip.id, to: index - 1) }
        .accessibilityAction(named: "Move right") { model.move(clip.id, to: index + 1) }
    }

    private func reorderGesture(for clip: TimelineClip) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    if draggingID == nil {
                        draggingID = clip.id
                        dragOffset = 0
                        Haptics.press()
                    }
                case .second(true, let drag):
                    if draggingID == nil {
                        draggingID = clip.id
                        Haptics.press()
                    }
                    let before = proposedIndex
                    dragOffset = drag?.translation.width ?? 0
                    if proposedIndex != before { Haptics.detent() }
                default:
                    break
                }
            }
            .onEnded { _ in
                if let id = draggingID, let to = proposedIndex, to != model.project.index(ofClip: id) {
                    model.move(id, to: to)
                }
                draggingID = nil
                dragOffset = 0
            }
    }

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
