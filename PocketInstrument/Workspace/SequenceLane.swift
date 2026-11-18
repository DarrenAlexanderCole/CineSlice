import EditCore
import SwiftUI

/// The whole sequence in composition time: clip segments on top, the reference
/// music's waveform below (when there is music), clip boundaries as ticks through
/// both, the loop bracket and the playhead.
///
/// Dragging the clip band always scrubs. Dragging the waveform scrubs in Arrange
/// and slides the music against the picture in Mix (unless the music is locked, when it
/// scrubs), so the two never share a gesture in the same state. The bracket's Signal handles set the loop (snapping to clip edges).
///
/// Pinch or the zoom key magnifies the lane around the playhead, for lining music up
/// closer than a frame-sized sliver of the whole sequence. Zoomed, scrubbing drags the
/// sequence under a fixed view like tape, and every drag moves time in finer steps.
///
/// While a curve is being edited by hand (`WorkspaceModel.curveEditTarget`), the curve band
/// grows and takes the touches: drag a point to move it, drag anywhere else to draw the
/// curve by finger, tap the band to add a point, and double-tap a point to delete it. The clip band still scrubs.
struct SequenceLane: View {
    enum WaveformDrag { case scrub, slideMusic }

    var model: WorkspaceModel
    var waveformDrag: WaveformDrag = .scrub
    /// Mix: draw the level curves (music in Signal, clip sound in Ivory) over the waveform.
    var showsAutomation = false

    private let rulerHeight: CGFloat = 22
    private var waveHeight: CGFloat { isEditingCurve ? 112 : 46 }
    private let bandGap: CGFloat = 2
    private let snapDistance: CGFloat = 10

    @State private var draftLoop: MediaTimeRange?
    @State private var loopDragBase: MediaTimeRange?
    @State private var draftOffset: MediaTime?
    @State private var offsetDragBase: MediaTime = .zero
    @State private var scrubBase: MediaTime?
    @State private var pinchBase: Double?
    @State private var pointGrab: PointGrab?
    @State private var lastPointTap: (handle: WorkspaceModel.CurveHandle, at: Date)?

    private var music: AudioTrack? { model.project.referenceAudio }
    private var isEditingCurve: Bool { showsAutomation && model.curveEditTarget != nil }
    /// Below the clip band: the music's waveform, or an empty curve band while editing a clip curve.
    private var hasBand: Bool { music != nil || isEditingCurve }
    private var totalHeight: CGFloat { rulerHeight + (hasBand ? bandGap + waveHeight : 0) }

    var body: some View {
        HStack(spacing: 6) {
            lane
            zoomKey
        }
    }

    private var lane: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                ruler(width: width)
                if let music {
                    waveBand(music, width: width)
                        .offset(y: rulerHeight + bandGap)
                } else if isEditingCurve {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.obsidian)
                        .frame(width: width, height: waveHeight)
                        .offset(y: rulerHeight + bandGap)
                }
                clipTicks(width: width)
                if showsAutomation {
                    let bandHeight = hasBand ? waveHeight : rulerHeight
                    AutomationCurves(model: model, window: window)
                        .frame(width: width, height: bandHeight)
                        .offset(y: hasBand ? rulerHeight + bandGap : 0)
                }
                if isEditingCurve {
                    curveEditor(width: width)
                        .offset(y: rulerHeight + bandGap)
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
            // Zoomed, content runs past the sides and is cut at them; whole, the loop handles may poke out.
            .mask(Rectangle().padding(.horizontal, zoom > 1 ? 0 : -8).padding(.vertical, -12))
            .coordinateSpace(name: "lane")
        }
        .frame(height: totalHeight)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .simultaneousGesture(pinchGesture)
        .accessibilityElement(children: .contain)
    }

    // MARK: Zoom

    /// Steps the zoom key cycles through; pinching goes anywhere between 1× and `maxZoom`.
    private static let zoomSteps: [Double] = [1, 4, 16]

    /// Enough to show half a second across the lane.
    private var maxZoom: Double { max(1, duration / 0.5) }
    private var zoom: Double { min(max(model.laneZoom, 1), maxZoom) }

    private var zoomKey: some View {
        Button {
            let next = Self.zoomSteps.first { $0 > zoom + 0.01 && $0 <= maxZoom } ?? 1
            model.laneZoom = next
            Haptics.detent()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: zoom > 1 ? "minus.magnifyingglass" : "plus.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                Text(zoomLabel).font(Theme.mono(10))
            }
        }
        .buttonStyle(.instrument(active: zoom > 1))
        .frame(height: max(Theme.minTouch, totalHeight))
        .accessibilityLabel("Zoom sequence")
        .accessibilityValue(zoomLabel)
        .accessibilityHint("Magnifies the sequence around the playhead. Pinch the sequence for any zoom.")
        .accessibilityAdjustableAction { direction in
            model.laneZoom = direction == .increment ? min(zoom * 2, maxZoom) : max(zoom / 2, 1)
        }
    }

    private var zoomLabel: String {
        let whole = (zoom - zoom.rounded()).magnitude < 0.05 || zoom >= 10
        return String(format: whole ? "%.0f×" : "%.1f×", zoom)
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if pinchBase == nil { pinchBase = zoom }
                model.laneZoom = min(max((pinchBase ?? 1) * g.magnification, 1), maxZoom)
            }
            .onEnded { _ in
                pinchBase = nil
                if model.laneZoom < 1.1 { model.laneZoom = 1 }
                Haptics.detent()
            }
    }

    // MARK: Geometry

    private var duration: Double { model.project.duration.seconds }

    /// The span of composition time (seconds) across the lane: all of it at 1×, otherwise a
    /// window centred on the playhead, held inside the sequence.
    private var window: (start: Double, span: Double) {
        guard zoom > 1 else { return (0, duration) }
        let span = duration / zoom
        let start = min(max(model.currentTime.seconds - span / 2, 0), duration - span)
        return (start, span)
    }

    private func x(for t: MediaTime, _ width: CGFloat) -> CGFloat {
        let w = window
        guard w.span > 0 else { return 0 }
        return CGFloat((t.seconds - w.start) / w.span) * width
    }

    /// A range's x extent, cut to the lane's sides so zoomed spans never outgrow (and shift) the lane.
    private func visible(_ range: MediaTimeRange, _ width: CGFloat) -> (CGFloat, CGFloat) {
        (min(max(x(for: range.start, width), 0), width), min(max(x(for: range.end, width), 0), width))
    }

    /// Composition time at x, snapped to the export frame grid.
    private func time(at x: CGFloat, _ width: CGFloat) -> MediaTime {
        let w = window
        let fraction = width > 0 ? Double(min(max(x / width, 0), 1)) : 0
        return frameTime(w.start + fraction * w.span)
    }

    /// Seconds on the export frame grid, inside the sequence.
    private func frameTime(_ seconds: Double) -> MediaTime {
        let fps = model.sequenceFrame.timescale
        return MediaTime(value: Int64((seconds * Double(fps)).rounded()), timescale: fps)
            .clamped(to: .zero, model.project.duration)
    }

    // MARK: Bands

    private func ruler(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.sequenceMap.entries, id: \.clipID) { entry in
                let (x0, x1) = visible(entry.compositionRange, width)
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
        let slides = waveformDrag == .slideMusic && !music.isLocked
        let sliding = draftOffset != nil
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.obsidian)
            if let placement = MusicPlacement(
                track: AudioTrack(fileName: music.fileName, duration: music.duration, offset: offset),
                sequenceDuration: model.project.duration)
            {
                let (x0, x1) = visible(placement.compositionRange, width)
                Rectangle().fill(Theme.olive.opacity(0.25))
                    .frame(width: max(1, x1 - x0), height: waveHeight)
                    .offset(x: x0)
            }
            if let waveform = model.waveform {
                // The lane spans the window in composition time; audio time is composition − offset.
                let w = window
                WaveformBars(
                    waveform: waveform, from: MediaTime(seconds: w.start) - offset,
                    to: MediaTime(seconds: w.start + w.span) - offset)
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
            slides
                ? AnyGesture(slideGesture(music, width: width).map { _ in () })
                : AnyGesture(scrubGesture(width: width).map { _ in () })
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slides ? "Music position" : music.isLocked ? "Music, locked" : "Music waveform")
        .accessibilityValue(
            String(
                format: "Song starts %.2f seconds %@ the video", abs(music.offset.seconds),
                music.offset <= .zero ? "before" : "into")
        )
        .accessibilityAdjustableAction { direction in
            guard slides else { return }
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

    /// Whole sequence: the playhead jumps to the finger. Zoomed: the sequence drags under the
    /// fixed view like tape, since the view itself follows the playhead.
    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if model.engine.isPlaying { model.engine.pause() }
                model.scrub(to: scrubTime(value, width), precise: false)
            }
            .onEnded { value in
                model.scrub(to: scrubTime(value, width), precise: true)
                scrubBase = nil
            }
    }

    private func scrubTime(_ value: DragGesture.Value, _ width: CGFloat) -> MediaTime {
        guard zoom > 1 else { return time(at: value.location.x, width) }
        if scrubBase == nil { scrubBase = model.currentTime }
        let base = scrubBase ?? model.currentTime
        return frameTime(base.seconds - Double(value.translation.width / max(width, 1)) * window.span)
    }

    /// One drag = one undo step: the offset is drafted while dragging and committed on release.
    private func slideGesture(_ music: AudioTrack, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                if draftOffset == nil {
                    offsetDragBase = music.offset
                    Haptics.press()
                }
                let seconds = Double(g.translation.width / max(width, 1)) * window.span
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

    // MARK: Curve point editing

    /// A touch on the curve band: on a point (dragging it once it moves), or on empty band.
    private struct PointGrab {
        let handle: WorkspaceModel.CurveHandle?
        var moved = false
    }

    /// How close a touch must land to pick up a point.
    private let pointReach: CGFloat = 22

    private func curveY(_ value: Float) -> CGFloat { 2 + CGFloat(1 - value) * (waveHeight - 4) }
    private func curveValue(_ y: CGFloat) -> Float { Float(min(max(1 - (y - 2) / (waveHeight - 4), 0), 1)) }

    private func curveEditor(width: CGFloat) -> some View {
        let handles = model.curveHandles.filter {
            let hx = x(for: $0.position.time, width)
            return hx >= -pointReach && hx <= width + pointReach
        }
        let range = model.curveEditRange
        let color = model.curveEditTarget == .music ? Theme.signal : Theme.ivory
        return ZStack(alignment: .topLeading) {
            // Outside the edited clip nothing can be added, so it's shaded.
            if let range {
                let (x0, x1) = visible(range, width)
                Rectangle().fill(Theme.obsidian.opacity(0.55)).frame(width: max(0, x0), height: waveHeight)
                Rectangle().fill(Theme.obsidian.opacity(0.55))
                    .frame(width: max(0, width - x1), height: waveHeight)
                    .offset(x: x1)
            }
            ForEach(handles, id: \.self) { handle in
                let grabbed =
                    pointGrab?.handle.map { $0.segment == handle.segment && $0.point == handle.point } ?? false
                Circle()
                    .fill(grabbed ? color : Theme.obsidian)
                    .overlay(Circle().strokeBorder(color, lineWidth: 2))
                    .frame(width: grabbed ? 16 : 12, height: grabbed ? 16 : 12)
                    .frame(width: Theme.minTouch, height: Theme.minTouch)
                    .offset(
                        x: x(for: handle.position.time, width) - Theme.minTouch / 2,
                        y: curveY(handle.position.value) - Theme.minTouch / 2
                    )
                    .accessibilityElement()
                    .accessibilityLabel("Curve point")
                    .accessibilityValue(
                        String(
                            format: "%d percent at %.2f seconds", Int((handle.position.value * 100).rounded()),
                            handle.position.time.seconds)
                    )
                    .accessibilityAdjustableAction { direction in
                        var moved = handle.position
                        moved.value += direction == .increment ? 0.05 : -0.05
                        model.dragCurvePoint(handle, to: moved)
                        model.commitCurveDraft()
                    }
                    .accessibilityAction(named: "Delete point") { model.removeCurvePoint(handle) }
            }
        }
        .frame(width: width, height: waveHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(pointGesture(handles, width: width))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.curveEditTarget == .music ? "Music curve" : "Clip curve")
        .accessibilityAction(named: "Add point at playhead") {
            let t = model.currentTime
            let level = model.mixProject.levelEnvelope(for: model.curveEditTarget ?? .music)
            let value = level.last { $0.time <= t }?.value ?? 1
            model.addCurvePoint(AutomationPoint(time: t, value: value))
        }
    }

    /// Drag a point to move it; drag anywhere else to draw; tap the band to add a point;
    /// double-tap a point to delete it.
    private func pointGesture(_ handles: [WorkspaceModel.CurveHandle], width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if pointGrab == nil {
                    let nearest = handles.min {
                        distance($0, to: g.startLocation, width) < distance($1, to: g.startLocation, width)
                    }
                    let hit = nearest.flatMap { distance($0, to: g.startLocation, width) <= pointReach ? $0 : nil }
                    pointGrab = PointGrab(handle: hit)
                    if hit != nil { Haptics.press() }
                }
                if !(pointGrab?.moved ?? false), hypot(g.translation.width, g.translation.height) < 3 { return }
                if pointGrab?.moved == false {
                    pointGrab?.moved = true
                    if pointGrab?.handle == nil {
                        // Off a point, a drag draws: start the stroke where the finger went down.
                        model.drawCurve(
                            to: AutomationPoint(
                                time: time(at: g.startLocation.x, width), value: curveValue(g.startLocation.y)))
                    }
                }
                guard let handle = pointGrab?.handle else {
                    model.drawCurve(
                        to: AutomationPoint(time: time(at: g.location.x, width), value: curveValue(g.location.y)))
                    return
                }
                let startX = x(for: handle.position.time, width)
                let startY = curveY(handle.position.value)
                model.dragCurvePoint(
                    handle,
                    to: AutomationPoint(
                        time: time(at: startX + g.translation.width, width),
                        value: curveValue(startY + g.translation.height)))
            }
            .onEnded { g in
                defer { pointGrab = nil }
                guard let grab = pointGrab else { return }
                if let handle = grab.handle {
                    if grab.moved {
                        model.commitCurveDraft()
                    } else if let last = lastPointTap, last.handle == handle, Date().timeIntervalSince(last.at) < 0.4 {
                        lastPointTap = nil
                        model.removeCurvePoint(handle)
                    } else {
                        lastPointTap = (handle, Date())
                    }
                } else if grab.moved {
                    model.commitCurveDraft()
                } else {
                    model.addCurvePoint(
                        AutomationPoint(time: time(at: g.location.x, width), value: curveValue(g.location.y)))
                }
            }
    }

    private func distance(_ handle: WorkspaceModel.CurveHandle, to location: CGPoint, _ width: CGFloat) -> CGFloat {
        hypot(x(for: handle.position.time, width) - location.x, curveY(handle.position.value) - location.y)
    }

    // MARK: Loop bracket

    private enum Edge { case start, end }

    private func loopBracket(_ loop: MediaTimeRange, width: CGFloat) -> some View {
        let x0 = x(for: loop.start, width)
        let x1 = x(for: loop.end, width)
        let (fill0, fill1) = visible(loop, width)
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.signal.opacity(0.14))
                .overlay(alignment: .top) { Rectangle().fill(Theme.signal).frame(height: 2) }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.signal).frame(height: 2) }
                .frame(width: max(2, fill1 - fill0), height: totalHeight)
                .offset(x: fill0)
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
    /// The lane's visible span of composition time, in seconds.
    var window: (start: Double, span: Double)

    var body: some View {
        let project = model.mixProject
        let recording = model.recording
        Canvas { context, size in
            guard window.span > 0 else { return }
            func point(_ p: AutomationPoint) -> CGPoint {
                CGPoint(
                    x: CGFloat((p.time.seconds - window.start) / window.span) * size.width,
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
                let lane = project.lane(for: target)
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
