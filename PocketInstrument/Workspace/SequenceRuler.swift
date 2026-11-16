import EditCore
import SwiftUI

/// The whole sequence at a glance, in composition time: clip segments, the
/// playhead and the loop bracket. Drag the ruler to scrub; drag the bracket's
/// Signal handles to set the loop region (they snap to clip edges).
struct SequenceRuler: View {
    var model: WorkspaceModel

    private let height: CGFloat = 26
    private let snapDistance: CGFloat = 10
    @State private var draftLoop: MediaTimeRange?
    @State private var dragBase: MediaTimeRange?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let map = model.sequenceMap
            ZStack(alignment: .topLeading) {
                ForEach(map.entries, id: \.clipID) { entry in
                    let x0 = x(for: entry.compositionRange.start, width)
                    let x1 = x(for: entry.compositionRange.end, width)
                    let selected = entry.clipID == model.selectedClipID
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(selected ? Theme.olive : Theme.instrument)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(selected ? Theme.signal.opacity(0.7) : Theme.hairline)
                        )
                        .frame(width: max(1, x1 - x0 - 1), height: height)
                        .offset(x: x0)
                }
                .allowsHitTesting(false)

                if let loop = draftLoop ?? model.activeLoop?.range {
                    loopBracket(loop, width: width)
                }

                Rectangle().fill(Theme.ivory)
                    .frame(width: 2, height: height + 8)
                    .shadow(color: Theme.ivory.opacity(0.8), radius: 3)
                    .offset(x: x(for: model.currentTime, width) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width))
            .coordinateSpace(name: "ruler")
        }
        .frame(height: height)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sequence")
    }

    // MARK: Geometry

    private var duration: Double { model.project.duration.seconds }

    private func x(for t: MediaTime, _ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(t.seconds / duration, 0), 1)) * width
    }

    /// Composition time at x, snapped to the export frame grid.
    private func time(at x: CGFloat, _ width: CGFloat) -> MediaTime {
        let fps = model.sequenceFrame.timescale
        let fraction = width > 0 ? Double(min(max(x / width, 0), 1)) : 0
        return MediaTime(value: Int64((fraction * duration * Double(fps)).rounded()), timescale: fps)
            .clamped(to: .zero, model.project.duration)
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

    private enum Edge { case start, end }

    private func loopBracket(_ loop: MediaTimeRange, width: CGFloat) -> some View {
        let x0 = x(for: loop.start, width)
        let x1 = x(for: loop.end, width)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.signal.opacity(0.16))
                .overlay(alignment: .top) { Rectangle().fill(Theme.signal).frame(height: 2) }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.signal).frame(height: 2) }
                .frame(width: max(2, x1 - x0), height: height)
                .offset(x: x0)
                .allowsHitTesting(false)
            handle(.start, x: x0, loop: loop, width: width)
            handle(.end, x: x1, loop: loop, width: width)
        }
    }

    private func handle(_ edge: Edge, x: CGFloat, loop: MediaTimeRange, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.signal)
            .frame(width: 6, height: height + 6)
            .frame(width: 44, height: height + 18)  // generous touch target
            .contentShape(Rectangle())
            .offset(x: x - 22, y: -9)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("ruler"))
                    .onChanged { value in
                        if dragBase == nil {
                            dragBase = loop
                            Haptics.press()
                        }
                        guard let base = dragBase else { return }
                        let baseX = self.x(for: edge == .start ? base.start : base.end, width)
                        let t = snapped(time(at: baseX + value.translation.width, width), width: width)
                        let previous = draftLoop
                        draftLoop =
                            edge == .start
                            ? MediaTimeRange(start: min(t, base.end - minimumClipDuration), end: base.end)
                            : MediaTimeRange(start: base.start, end: max(t, base.start + minimumClipDuration))
                        if let previous, previous != draftLoop, isClipEdge(t) { Haptics.detent() }
                    }
                    .onEnded { _ in
                        if let final = draftLoop { model.setLoopRange(final) }
                        draftLoop = nil
                        dragBase = nil
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(edge == .start ? "Loop start" : "Loop end")
            .accessibilityValue(String(format: "%.2f seconds", (edge == .start ? loop.start : loop.end).seconds))
            .accessibilityAdjustableAction { direction in
                let step = MediaTime(seconds: direction == .increment ? 0.5 : -0.5)
                model.setLoopRange(
                    edge == .start
                        ? MediaTimeRange(start: loop.start + step, end: loop.end)
                        : MediaTimeRange(start: loop.start, end: loop.end + step))
            }
    }

    private var clipEdges: [MediaTime] {
        [.zero] + model.sequenceMap.entries.map(\.compositionRange.end)
    }

    private func isClipEdge(_ t: MediaTime) -> Bool { clipEdges.contains(t) }

    /// Pulls a time onto the nearest clip edge when it's within `snapDistance` points.
    private func snapped(_ t: MediaTime, width: CGFloat) -> MediaTime {
        let tx = x(for: t, width)
        guard let nearest = clipEdges.min(by: { abs(x(for: $0, width) - tx) < abs(x(for: $1, width) - tx) }),
            abs(x(for: nearest, width) - tx) <= snapDistance
        else { return t }
        return nearest
    }
}
