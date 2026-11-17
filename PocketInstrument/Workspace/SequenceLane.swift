import EditCore
import SwiftUI

/// The whole sequence in composition time: clip segments on top, the reference
/// music's waveform below (when there is music), clip boundaries as ticks through
/// both, the loop bracket and the playhead.
///
/// Dragging the clip band always scrubs. Dragging the waveform scrubs in Arrange
/// and slides the music against the picture in Mix, so the two never share a gesture
/// in the same state. The bracket's Signal handles set the loop (snapping to clip edges).
struct SequenceLane: View {
    enum WaveformDrag { case scrub, slideMusic }

    var model: WorkspaceModel
    var waveformDrag: WaveformDrag = .scrub
    /// Mix: draw the level curves (music in Signal, clip sound in Ivory) over the waveform.
    var showsAutomation = false

    private let rulerHeight: CGFloat = 22
    private let waveHeight: CGFloat = 46
    private let bandGap: CGFloat = 2
    private let snapDistance: CGFloat = 10

    @State private var draftLoop: MediaTimeRange?
    @State private var loopDragBase: MediaTimeRange?
    @State private var draftOffset: MediaTime?
    @State private var offsetDragBase: MediaTime = .zero

    private var music: AudioTrack? { model.project.referenceAudio }
    private var totalHeight: CGFloat { rulerHeight + (music == nil ? 0 : bandGap + waveHeight) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ruler(width: width)
                if let music {
                    waveBand(music, width: width)
                        .offset(y: rulerHeight + bandGap)
                }
                clipTicks(width: width)
                if showsAutomation {
                    let bandHeight = music == nil ? rulerHeight : waveHeight
                    AutomationCurves(model: model)
                        .frame(width: width, height: bandHeight)
                        .offset(y: music == nil ? 0 : rulerHeight + bandGap)
                }
                if let loop = draftLoop ?? model.activeLoop?.range {
                    loopBracket(loop, width: width)
                }
                Rectangle().fill(Theme.ivory)
                    .frame(width: 2, height: totalHeight + 8)
                    .shadow(color: Theme.ivory.opacity(0.8), radius: 3)
                    .offset(x: x(for: model.currentTime, width) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: totalHeight, alignment: .topLeading)
            .coordinateSpace(name: "lane")
        }
        .frame(height: totalHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
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

    // MARK: Bands

    private func ruler(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.sequenceMap.entries, id: \.clipID) { entry in
                let x0 = x(for: entry.compositionRange.start, width)
                let x1 = x(for: entry.compositionRange.end, width)
                let selected = entry.clipID == model.selectedClipID
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(selected ? Theme.olive : Theme.instrument)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(selected ? Theme.signal.opacity(0.7) : Theme.hairline)
                    )
                    .frame(width: max(1, x1 - x0 - 1), height: rulerHeight)
                    .offset(x: x0)
            }
        }
        .frame(width: width, height: rulerHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(scrubGesture(width: width))
        .accessibilityElement()
        .accessibilityLabel("Sequence")
        .accessibilityValue(String(format: "Playhead at %.2f seconds", model.currentTime.seconds))
    }

    private func waveBand(_ music: AudioTrack, width: CGFloat) -> some View {
        let offset = draftOffset ?? music.offset
        let sliding = draftOffset != nil
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.obsidian)
            if let placement = MusicPlacement(
                track: AudioTrack(fileName: music.fileName, duration: music.duration, offset: offset),
                sequenceDuration: model.project.duration)
            {
                let x0 = x(for: placement.compositionRange.start, width)
                let x1 = x(for: placement.compositionRange.end, width)
                Rectangle().fill(Theme.olive.opacity(0.25))
                    .frame(width: max(1, x1 - x0), height: waveHeight)
                    .offset(x: x0)
            }
            if let waveform = model.waveform {
                // The lane spans composition 0…duration, i.e. audio −offset…duration−offset.
                WaveformBars(
                    waveform: waveform, from: MediaTime.zero - offset, to: model.project.duration - offset)
            } else {
                Text(model.musicURL == nil ? "Music file is missing" : "Reading waveform…")
                    .font(Theme.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(music.originalFilename ?? "Music")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.label.opacity(0.8))
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: waveHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(sliding ? Theme.signal : Theme.hairline)
        )
        .contentShape(Rectangle())
        .gesture(
            waveformDrag == .slideMusic
                ? AnyGesture(slideGesture(music, width: width).map { _ in () })
                : AnyGesture(scrubGesture(width: width).map { _ in () })
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(waveformDrag == .slideMusic ? "Music position" : "Music waveform")
        .accessibilityValue(
            String(
                format: "Song starts %.2f seconds %@ the video", abs(music.offset.seconds),
                music.offset <= .zero ? "before" : "into")
        )
        .accessibilityAdjustableAction { direction in
            guard waveformDrag == .slideMusic else { return }
            model.setMusicOffset(music.offset + MediaTime(seconds: direction == .increment ? 1 : -1))
        }
    }

    /// Clip boundaries as ticks, so cuts can be lined up with beats in the waveform.
    private func clipTicks(width: CGFloat) -> some View {
        let edges = model.sequenceMap.entries.dropLast().map(\.compositionRange.end)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(edges.enumerated()), id: \.offset) { _, edge in
                Rectangle().fill(Theme.ivory.opacity(0.55))
                    .frame(width: 1, height: totalHeight)
                    .offset(x: x(for: edge, width) - 0.5)
            }
        }
        .allowsHitTesting(false)
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

    /// One drag = one undo step: the offset is drafted while dragging and committed on release.
    private func slideGesture(_ music: AudioTrack, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                if draftOffset == nil {
                    offsetDragBase = music.offset
                    Haptics.press()
                }
                let seconds = Double(g.translation.width / max(width, 1)) * duration
                // Snap to the export frame grid; the ±10 ms buttons go finer.
                let fps = model.sequenceFrame.timescale
                let proposed = MediaTime(
                    value: Int64(((offsetDragBase.seconds + seconds) * Double(fps)).rounded()), timescale: fps)
                draftOffset = music.clampedOffset(proposed, sequenceDuration: model.project.duration)
            }
            .onEnded { _ in
                if let final = draftOffset { model.setMusicOffset(final) }
                draftOffset = nil
                Haptics.detent()
            }
    }

    // MARK: Loop bracket

    private enum Edge { case start, end }

    private func loopBracket(_ loop: MediaTimeRange, width: CGFloat) -> some View {
        let x0 = x(for: loop.start, width)
        let x1 = x(for: loop.end, width)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.signal.opacity(0.14))
                .overlay(alignment: .top) { Rectangle().fill(Theme.signal).frame(height: 2) }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.signal).frame(height: 2) }
                .frame(width: max(2, x1 - x0), height: totalHeight)
                .offset(x: x0)
                .allowsHitTesting(false)
            handle(.start, x: x0, loop: loop, width: width)
            handle(.end, x: x1, loop: loop, width: width)
        }
    }

    private func handle(_ edge: Edge, x: CGFloat, loop: MediaTimeRange, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Theme.signal)
            .overlay(Capsule().fill(Theme.obsidian).frame(width: 1.5, height: 12))
            .frame(width: 7, height: totalHeight + 6)
            .frame(width: 44, height: totalHeight + 18)  // generous touch target
            .contentShape(Rectangle())
            .offset(x: x - 22, y: -9)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("lane"))
                    .onChanged { value in
                        if loopDragBase == nil {
                            loopDragBase = loop
                            Haptics.press()
                        }
                        guard let base = loopDragBase else { return }
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
                        loopDragBase = nil
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

/// Peak bars for the audio-time span [from, to), stretched across the view's width.
/// Times outside the song draw nothing.
struct WaveformBars: View {
    let waveform: Waveform
    let from: MediaTime
    let to: MediaTime
    var color: Color = Theme.signal.opacity(0.85)

    var body: some View {
        Canvas { context, size in
            let barWidth: CGFloat = 2
            let gap: CGFloat = 1
            let count = max(1, Int(size.width / (barWidth + gap)))
            let levels = waveform.envelope(from: from, to: to, buckets: count)
            let step = size.width / CGFloat(count)
            let mid = size.height / 2
            for (i, level) in levels.enumerated() where level > 0 {
                let h = max(1, CGFloat(level) * (size.height - 6))
                let rect = CGRect(x: CGFloat(i) * step, y: mid - h / 2, width: barWidth, height: h)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The level curves across the sequence: the playing envelope faintly, recorded passes
/// bold, and a pass being recorded brightest. Top is full level, bottom is silence.
private struct AutomationCurves: View {
    var model: WorkspaceModel

    var body: some View {
        let project = model.project
        let duration = project.duration.seconds
        let recording = model.recording
        Canvas { context, size in
            guard duration > 0 else { return }
            func point(_ p: AutomationPoint) -> CGPoint {
                CGPoint(
                    x: CGFloat(min(max(p.time.seconds / duration, 0), 1)) * size.width,
                    y: 2 + CGFloat(1 - p.value) * (size.height - 4))
            }
            func line(_ points: [AutomationPoint]) -> Path {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: point(first))
                    for p in points.dropFirst() { path.addLine(to: point(p)) }
                }
            }
            for target in [AutomationTarget.clipAudio, .music] {
                let lane = project.automation[target]
                let color = target == .music ? Theme.signal : Theme.ivory
                if !lane.isEmpty {
                    context.stroke(
                        line(project.levelEnvelope(for: target)), with: .color(color.opacity(0.45)), lineWidth: 1)
                    for segment in lane.segments {
                        // A dark outline keeps the curve readable over the waveform's bars.
                        context.stroke(
                            line(segment.points), with: .color(Theme.obsidian),
                            style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                        context.stroke(
                            line(segment.points), with: .color(color),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
                if let recording, recording.target == target {
                    context.stroke(
                        line(recording.samples), with: .color(Theme.obsidian),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    var glow = context
                    glow.addFilter(.shadow(color: color, radius: 3))
                    glow.stroke(
                        line(recording.samples), with: .color(color),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
