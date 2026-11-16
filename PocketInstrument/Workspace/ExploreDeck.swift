import EditCore
import SwiftUI

/// Explore state: the selected clip's whole source as a filmstrip. Drag the
/// strip to scrub; drag the Signal handles (or use Mark In / Mark Out) to set
/// the clip's in/out. Everything is in *source* time; nothing touches the file.
struct ExploreDeck: View {
    var model: WorkspaceModel

    var body: some View {
        VStack(spacing: 12) {
            if let clip = model.selectedClip, let source = model.selectedSource {
                Filmstrip(model: model, clip: clip, source: source)
                readouts(range: model.draftRange ?? clip.sourceRange, frameRate: source.frameRate)
            }
            TransportRow(model: model) {
                Button("In") { model.markIn() }
                    .buttonStyle(.instrument(.key))
                    .accessibilityLabel("Mark in at playhead")
            } trailing: {
                Button("Out") { model.markOut() }
                    .buttonStyle(.instrument(.key))
                    .accessibilityLabel("Mark out at playhead")
            }
            HStack(spacing: 8) {
                Spacer()
                LoopButton(model: model)
            }
        }
    }

    private func readouts(range: MediaTimeRange, frameRate: Double) -> some View {
        HStack {
            readout("IN", range.start, frameRate, .leading)
            readout("LENGTH", range.duration, frameRate, .center, highlight: true)
            readout("OUT", range.end, frameRate, .trailing)
        }
    }

    private func readout(
        _ title: String, _ time: MediaTime, _ fps: Double, _ alignment: HorizontalAlignment,
        highlight: Bool = false
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title).font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
            TimecodeText(time: time, frameRate: fps, size: 14, color: highlight ? Theme.signal : Theme.label)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
    }
}

struct Filmstrip: View {
    var model: WorkspaceModel
    let clip: TimelineClip
    let source: SourceAsset

    private let height: CGFloat = 58
    private let handleWidth: CGFloat = 16
    @State private var dragBase: MediaTimeRange?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let range = model.draftRange ?? clip.sourceRange
            let inX = x(for: range.start, width)
            let outX = x(for: range.end, width)
            let playX = x(for: model.currentTime, width)

            ZStack(alignment: .topLeading) {
                frames(width: width)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .gesture(scrubGesture(width: width))

                // Dim everything outside the clip.
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: max(0, inX), height: height)
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: max(0, width - outX), height: height)
                    .offset(x: outX)
                    .allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.signal, lineWidth: 2)
                    .frame(width: max(handleWidth, outX - inX), height: height + 4)
                    .offset(x: inX, y: -2)
                    .shadow(color: Theme.signal.opacity(0.4), radius: 6)
                    .allowsHitTesting(false)

                handle(edge: .start, x: inX, width: width)
                handle(edge: .end, x: outX, width: width)

                Rectangle().fill(Theme.ivory)
                    .frame(width: 2, height: height + 12)
                    .shadow(color: Theme.ivory.opacity(0.8), radius: 3)
                    .offset(x: playX - 1, y: -6)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: "filmstrip")
        }
        .frame(height: height)
        .padding(.horizontal, handleWidth / 2)
        .accessibilityElement(children: .contain)
    }

    // MARK: Geometry

    private func x(for t: MediaTime, _ width: CGFloat) -> CGFloat {
        let d = source.duration.seconds
        guard d > 0 else { return 0 }
        return CGFloat(min(max(t.seconds / d, 0), 1)) * width
    }

    private func time(at x: CGFloat, _ width: CGFloat) -> MediaTime {
        let fraction = width > 0 ? Double(min(max(x / width, 0), 1)) : 0
        // Snap to the source's frame grid.
        let fps = Int32(max(1, source.frameRate.rounded()))
        let frames = (fraction * source.duration.seconds * Double(fps)).rounded()
        return MediaTime(value: Int64(frames), timescale: fps).clamped(to: .zero, source.duration)
    }

    // MARK: Frames

    private func frames(width: CGFloat) -> some View {
        let count = max(4, Int(width / 44))
        let url = model.mediaURL(for: source)
        return HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { i in
                let t = MediaTime(seconds: source.duration.seconds * (Double(i) + 0.5) / Double(count))
                VideoFrameView(url: url, time: t.cmTime, maxPixel: 120)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.obsidian)
    }

    // MARK: Gestures

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if model.engine.isPlaying { model.engine.pause() }
                model.scrub(to: time(at: value.location.x, width), precise: false)
            }
            .onEnded { value in
                model.scrub(to: time(at: value.location.x, width), precise: true)
            }
    }

    private enum TrimEdge { case start, end }

    private func handle(edge: TrimEdge, x: CGFloat, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Theme.signal)
            .overlay(Capsule().fill(Theme.obsidian).frame(width: 2, height: 18))
            .frame(width: handleWidth, height: height + 4)
            .frame(width: 44, height: height + 20)  // generous touch target
            .contentShape(Rectangle())
            .offset(x: x - 22, y: -10)
            .highPriorityGesture(
                // Measured in the strip's fixed space so the moving handle doesn't skew translation.
                DragGesture(minimumDistance: 0, coordinateSpace: .named("filmstrip"))
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = model.draftRange ?? clip.sourceRange
                            model.engine.pause()
                            Haptics.press()
                        }
                        guard let base = dragBase else { return }
                        let baseX = self.x(for: edge == .start ? base.start : base.end, width)
                        let t = time(at: baseX + value.translation.width, width)
                        let proposed =
                            edge == .start
                            ? MediaTimeRange(start: t, end: base.end)
                            : MediaTimeRange(start: base.start, end: t)
                        model.updateDraft(proposed, previewAt: t)
                    }
                    .onEnded { _ in
                        dragBase = nil
                        model.commitDraft()
                        Haptics.detent()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? "In point" : "Out point")
            .accessibilityValue(
                String(format: "%.2f seconds", (edge == .start ? clip.sourceRange.start : clip.sourceRange.end).seconds)
            )
            .accessibilityAdjustableAction { direction in
                let step = source.frameDuration
                let delta = direction == .increment ? step : MediaTime.zero - step
                var r = clip.sourceRange
                if edge == .start {
                    r = MediaTimeRange(start: r.start + delta, end: r.end)
                } else {
                    r = MediaTimeRange(start: r.start, end: r.end + delta)
                }
                model.perform(TrimClipCommand(clipID: clip.id, sourceRange: r))
            }
    }
}
