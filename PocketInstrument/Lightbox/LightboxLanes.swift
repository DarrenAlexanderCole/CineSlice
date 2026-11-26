import AVFoundation
import EditCore
import SwiftUI

/// The time ruler across the top of the light box: labelled marks at a step that suits the zoom,
/// four small ticks between. Dragging along it scrubs the playhead.
struct TimeRuler: View {
    var viewport: TimelineViewport
    var onScrub: (Double, _ ended: Bool) -> Void

    var body: some View {
        Canvas { context, size in
            let step = viewport.rulerStep()
            let minor = step / 4
            // From 00:00: the lead-in before it is bare.
            let first = max(0, (viewport.start / minor).rounded(.down) * minor)
            var t = first
            var i = Int((first / minor).rounded())
            let end = viewport.seconds(atX: size.width)
            while t <= end + minor {
                let x = viewport.x(for: t)
                let major = i % 4 == 0
                let h: CGFloat = major ? 7 : 3.5
                context.fill(
                    Path(CGRect(x: x - 0.5, y: size.height - h, width: 1, height: h)),
                    with: .color(Color(hex: 0x3A3A30).opacity(major ? 0.8 : 0.45)))
                if major, t >= 0 {
                    let label = Text(Self.label(t, step: step))
                        .font(Theme.mono(9, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x3A3A30))
                    context.draw(label, at: CGPoint(x: x, y: 6), anchor: .top)
                }
                t += minor
                i += 1
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onScrub(viewport.seconds(atX: $0.location.x), false) }
                .onEnded { onScrub(viewport.seconds(atX: $0.location.x), true) }
        )
        .accessibilityHidden(true)
    }

    /// "00:24", or "00:24.5" when the marks are half a second apart.
    static func label(_ seconds: Double, step: Double) -> String {
        let whole = Int(seconds)
        let base = String(format: "%02d:%02d", whole / 60, whole % 60)
        return step < 1 ? base + String(format: ".%d", Int((seconds - Double(whole)) * 10)) : base
    }
}

/// A clip on the video lane as a strip of lit film: real frames from its source between amber
/// edges with understated perforations, and when the source has sound, its waveform in a band
/// along the bottom. Only the part on screen is built, and frames sit at fixed times so they
/// don't swim while panning. Taller lanes show more; short ones drop the perforations and sound.
struct FilmStripClip: View {
    let clip: TimelineClip
    let source: SourceAsset?
    let url: URL?
    let waveform: Waveform?
    /// Composition time where the clip starts, in seconds.
    let start: Double
    let viewport: TimelineViewport
    let lanesWidth: Double
    let height: Double
    let isSelected: Bool

    var body: some View {
        let duration = clip.compositionDuration.seconds
        let x0 = viewport.x(for: start)
        let x1 = viewport.x(for: start + duration)
        // Only the part on screen, with a little margin so the rounded ends stay off-screen.
        let vx0 = max(x0, -16)
        let vx1 = min(x1, lanesWidth + 16)
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(
                LinearGradient(
                    colors: [Theme.filmAmber.opacity(0.92), Color(hex: 0x7A3410).opacity(0.95)], startPoint: .top,
                    endPoint: .bottom))
            if showsPerforations {
                perforations(phase: vx0 - x0, width: vx1 - vx0)
            }
            frames(visibleFrom: viewport.seconds(atX: vx0), to: viewport.seconds(atX: vx1), offsetX: vx0)
                .frame(width: max(0, vx1 - vx0 - 4), height: imageHeight)
                .clipped()
                .offset(x: 2, y: perforationBand)
            if let waveform, waveBand > 0 {
                WaveformBars(
                    waveform: waveform,
                    from: sourceTime(atComposition: viewport.seconds(atX: vx0)),
                    to: sourceTime(atComposition: viewport.seconds(atX: vx1)),
                    color: Theme.ivory.opacity(clip.volume > 0 ? 0.85 : 0.3)
                )
                .frame(width: max(0, vx1 - vx0 - 4), height: waveBand)
                .offset(x: 2, y: perforationBand + imageHeight)
            }
        }
        .frame(width: max(0, vx1 - vx0), height: height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isSelected ? Theme.signal : Color(hex: 0xFF9A4A).opacity(0.55), lineWidth: isSelected ? 2.5 : 1)
        )
        .shadow(
            color: isSelected ? Theme.signal.opacity(0.7) : Theme.filmAmber.opacity(0.35), radius: isSelected ? 6 : 4
        )
        .offset(x: vx0)
        .accessibilityElement()
        .accessibilityLabel(source?.originalFilename ?? "Clip")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var showsPerforations: Bool { height >= 46 }
    private var perforationBand: Double { showsPerforations ? (height >= 100 ? 9 : 7) : 2 }
    /// Room for the clip's own sound along the bottom, only when it has some.
    private var waveBand: Double {
        guard source?.hasAudio == true, height >= 46 else { return 0 }
        return height >= 100 ? 20 : 12
    }
    private var imageHeight: Double { max(8, height - perforationBand * 2 - waveBand) }

    private var accessibilityValue: String {
        let seconds = String(
            format: "starts at %.1f seconds, %.1f seconds long", start, clip.compositionDuration.seconds)
        return url == nil ? "Media missing, " + seconds : seconds
    }

    /// Source time heard at composition time `t` inside this clip.
    private func sourceTime(atComposition t: Double) -> MediaTime {
        let local = min(max(t - start, 0), clip.compositionDuration.seconds)
        return clip.sourceRange.start + MediaTime(seconds: local * clip.speed)
    }

    /// Small rounded holes along both edges, sliding with the clip.
    private func perforations(phase: Double, width: Double) -> some View {
        Canvas { context, size in
            let pitch: CGFloat = height >= 100 ? 11 : 9
            let hole = CGSize(width: pitch * 0.45, height: perforationBand * 0.5)
            var x = -CGFloat(phase.truncatingRemainder(dividingBy: Double(pitch))) + 2
            while x < size.width {
                for y in [(perforationBand - hole.height) / 2, size.height - (perforationBand + hole.height) / 2] {
                    context.fill(
                        Path(roundedRect: CGRect(origin: CGPoint(x: x, y: y), size: hole), cornerRadius: 1),
                        with: .color(Theme.lightTable.opacity(0.75)))
                }
                x += pitch
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    /// The frames on screen: each covers `tile` seconds of the timeline, starting on a multiple
    /// of `tile` from the clip's start, showing the source frame at its start.
    private func frames(visibleFrom t0: Double, to t1: Double, offsetX: Double) -> some View {
        let aspect = source.map { Double($0.width) / Double(max($0.height, 1)) } ?? 16 / 9
        let tileWidthNominal = imageHeight * min(max(aspect, 0.56), 1.78)
        let tile = viewport.tileDuration(nominalWidth: tileWidthNominal)
        let duration = clip.compositionDuration.seconds
        let first = max(0, Int(((t0 - start) / tile).rounded(.down)))
        let last = max(first, Int(((min(t1, start + duration) - start) / tile).rounded(.up)) - 1)
        let tilePoints = tile * viewport.pointsPerSecond
        let sourceEnd = clip.sourceRange.end.seconds - (source.map { 1 / $0.frameRate } ?? 1.0 / 30)
        return ZStack(alignment: .topLeading) {
            ForEach(first...last, id: \.self) { k in
                let local = Double(k) * tile
                let sourceSeconds = min(clip.sourceRange.start.seconds + local * clip.speed, sourceEnd)
                VideoFrameView(
                    url: url, time: CMTime(seconds: max(0, sourceSeconds), preferredTimescale: 600),
                    maxPixel: max(96, imageHeight * 2.2)
                )
                .frame(width: max(1, tilePoints - 1.5), height: imageHeight)
                .offset(x: viewport.x(for: start + local) - offsetX - 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The reference music as a strip of sage acetate where it's heard, its waveform printed on it
/// and light coming through. Dimmed when its level is down to nothing.
struct AudioGlassClip: View {
    let music: AudioTrack
    /// Where the sequence ends, in seconds: the song is cut off there.
    let sequenceEnd: Double
    let waveform: Waveform?
    let viewport: TimelineViewport
    let lanesWidth: Double
    let height: Double
    /// Held up by a long press and sliding: shows where the song now starts.
    var isLifted = false

    var body: some View {
        let start = music.timelineRange.start.seconds
        let end = music.timelineRange.end.seconds
        let vx0 = max(viewport.x(for: start), -16)
        let vx1 = min(viewport.x(for: end), lanesWidth + 16)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let audible = music.volume > 0
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [Theme.acetate.opacity(0.55), Theme.acetate.opacity(0.38)], startPoint: .top,
                    endPoint: .bottom))
            // Light through the acetate: brighter along its middle.
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.1), .init(color: .white.opacity(0.35), location: 0.5),
                        .init(color: .clear, location: 0.9),
                    ], startPoint: .top, endPoint: .bottom))
            if let waveform {
                WaveformBars(
                    waveform: waveform,
                    from: audioTime(viewport.seconds(atX: vx0)),
                    to: audioTime(viewport.seconds(atX: vx1)),
                    color: Theme.acetateInk.opacity(0.9)
                )
                .padding(.horizontal, 2)
            }
        }
        .frame(width: max(0, vx1 - vx0), height: height)
        .overlay(alignment: .leading) {
            // Past the sequence's end the song doesn't play: shaded.
            let cut = min(max(viewport.x(for: sequenceEnd) - vx0, 0), max(0, vx1 - vx0))
            if cut < vx1 - vx0 {
                shape.fill(Theme.obsidian.opacity(0.22))
                    .frame(width: vx1 - vx0 - cut)
                    .offset(x: cut)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if isLifted {
                // Where the song's start sits against the sequence: before it (−) or after (+).
                Text(String(format: "SONG %@%.2f s", music.offset.seconds < 0 ? "−" : "+", abs(music.offset.seconds)))
                    .font(Theme.mono(8, weight: .bold))
                    .foregroundStyle(Theme.acetateInk)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.6)))
                    .padding(4)
            } else if music.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.acetateInk.opacity(0.8))
                    .padding(5)
            }
        }
        .overlay(
            shape.strokeBorder(
                isLifted ? Theme.signal : Theme.acetateInk.opacity(0.35), lineWidth: isLifted ? 2.5 : 1)
        )
        .opacity(audible ? 1 : 0.4)
        .shadow(color: Theme.acetate.opacity(0.5), radius: 3)
        .offset(x: vx0)
        .accessibilityElement()
        .accessibilityLabel("Music: \(music.originalFilename ?? "reference track")")
        .accessibilityValue(
            "Lane A\(music.audioLane + 1), " + (audible ? "level \(Int(music.volume * 100)) percent" : "muted")
                + (music.isLocked ? ", locked" : "")
        )
        .accessibilityHint(
            music.isLocked ? "Unlock it in Mix to move it." : "Hold and drag to slide it along or onto another lane.")
    }

    /// Position in the song at composition time `t`.
    private func audioTime(_ t: Double) -> MediaTime { MediaTime(seconds: t) - music.offset }
}

/// A sound on one of the lanes under the music: a strip of cooler acetate with its waveform
/// printed on it and its name in the corner. Lifted, it can be refused where it would land on
/// another sound, and shows so in red.
struct SoundGlassClip: View {
    let clip: SoundClip
    let waveform: Waveform?
    /// Where it starts on the timeline, in seconds (moves with a drag).
    let start: Double
    let viewport: TimelineViewport
    let lanesWidth: Double
    let height: Double
    let isSelected: Bool
    var isBlocked = false
    var isMuted = false

    var body: some View {
        let length = clip.sourceRange.duration.seconds
        // Only the part on screen, so its name sits at the visible left edge.
        let vx0 = max(viewport.x(for: start), -16)
        let vx1 = min(viewport.x(for: start + length), lanesWidth + 16)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        let tint = isBlocked ? Theme.playhead : Theme.soundGlass
        ZStack(alignment: .topLeading) {
            shape.fill(
                LinearGradient(colors: [tint.opacity(0.6), tint.opacity(0.42)], startPoint: .top, endPoint: .bottom))
            shape.fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.1), .init(color: .white.opacity(0.3), location: 0.5),
                        .init(color: .clear, location: 0.9),
                    ], startPoint: .top, endPoint: .bottom))
            if let waveform {
                WaveformBars(
                    waveform: waveform,
                    from: fileTime(viewport.seconds(atX: vx0)),
                    to: fileTime(viewport.seconds(atX: vx1)),
                    color: Theme.soundInk.opacity(0.85)
                )
                .padding(.horizontal, 2)
            }
            if clip.volume < 1 || clip.fadeIn > .zero || clip.fadeOut > .zero {
                levelLine(vx0: vx0)
            }
            if height >= 30, vx1 - vx0 > 40 {
                Text(clip.originalFilename ?? "Sound")
                    .font(Theme.mono(7, weight: .bold))
                    .foregroundStyle(Theme.soundInk)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.top, 3)
            }
        }
        .frame(width: max(0, vx1 - vx0), height: height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isSelected ? Theme.signal : Theme.soundInk.opacity(0.35), lineWidth: isSelected ? 2.5 : 1)
        )
        .opacity(isMuted || clip.volume <= 0 ? 0.4 : 1)
        .shadow(
            color: isSelected ? Theme.signal.opacity(0.6) : Theme.soundGlass.opacity(0.5), radius: isSelected ? 5 : 3
        )
        .offset(x: vx0)
        .accessibilityElement()
        .accessibilityLabel("Sound: \(clip.originalFilename ?? "sound")")
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var spokenValue: String {
        var parts = [
            String(
                format: "starts at %.1f seconds, %.1f seconds long", clip.start.seconds,
                clip.sourceRange.duration.seconds),
            "level \(Int((clip.volume * 100).rounded())) percent",
        ]
        if clip.fadeIn > .zero { parts.append(String(format: "fades in over %.1f seconds", clip.fadeIn.seconds)) }
        if clip.fadeOut > .zero { parts.append(String(format: "fades out over %.1f seconds", clip.fadeOut.seconds)) }
        return parts.joined(separator: ", ")
    }

    /// The sound's level across it, the fades as slopes: the glass above the line is shaded off,
    /// as what's cut away.
    private func levelLine(vx0: Double) -> some View {
        Canvas { context, size in
            let length = clip.sourceRange.duration.seconds
            let x = { (t: Double) in viewport.x(for: start + t) - vx0 }
            let y = { (v: Float) in 4 + (1 - Double(v)) * (size.height - 8) }
            var line = Path()
            line.move(to: CGPoint(x: x(0), y: y(clip.fadeIn > .zero ? 0 : clip.volume)))
            line.addLine(to: CGPoint(x: x(clip.fadeIn.seconds), y: y(clip.volume)))
            line.addLine(to: CGPoint(x: x(length - clip.fadeOut.seconds), y: y(clip.volume)))
            line.addLine(to: CGPoint(x: x(length), y: y(clip.fadeOut > .zero ? 0 : clip.volume)))
            var shade = line
            shade.addLine(to: CGPoint(x: x(length), y: 0))
            shade.addLine(to: CGPoint(x: x(0), y: 0))
            shade.closeSubpath()
            context.fill(shade, with: .color(Theme.soundInk.opacity(0.28)))
            context.stroke(line, with: .color(Theme.soundInk), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    /// Position in the file at timeline time `t`.
    private func fileTime(_ t: Double) -> MediaTime {
        clip.sourceRange.start + MediaTime(seconds: min(max(t - start, 0), clip.sourceRange.duration.seconds))
    }
}

/// Long press, then drag: lifts a clip or sound to move it, reporting the finger in the named
/// coordinate space. On iOS 18+ it's a UIKit long press, which yields to the table's
/// pan when the finger moves first; on iOS 17, SwiftUI's long press sequenced before a drag.
struct ClipLiftGesture: ViewModifier {
    enum Phase { case began, changed, ended, cancelled }
    var space: String
    var action: (Phase, CGPoint) -> Void

    static let pressDuration = 0.3

    init(space: String, action: @escaping (Phase, CGPoint) -> Void) {
        self.space = space
        self.action = action
    }

    @GestureState private var isPressing = false
    @State private var hasBegun = false

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(LiftPress(space: space, action: action))
        } else {
            content
                .gesture(
                    LongPressGesture(minimumDuration: Self.pressDuration)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(space)))
                        .updating($isPressing) { _, state, _ in state = true }
                        .onChanged { value in
                            guard case .second(true, let drag?) = value else { return }
                            if !hasBegun {
                                hasBegun = true
                                action(.began, drag.startLocation)
                            }
                            action(.changed, drag.location)
                        }
                        .onEnded { value in
                            guard hasBegun else { return }
                            hasBegun = false
                            if case .second(true, let drag?) = value { action(.ended, drag.location) }
                        }
                )
                .onChange(of: isPressing) { _, pressing in
                    // A cancelled SwiftUI gesture never calls onEnded.
                    if !pressing, hasBegun {
                        hasBegun = false
                        action(.cancelled, .zero)
                    }
                }
        }
    }
}

@available(iOS 18.0, *)
private struct LiftPress: UIGestureRecognizerRepresentable {
    var space: String
    var action: (ClipLiftGesture.Phase, CGPoint) -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = ClipLiftGesture.pressDuration
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let point = context.converter.location(in: .named(space))
        switch recognizer.state {
        case .began: action(.began, point)
        case .changed: action(.changed, point)
        case .ended: action(.ended, point)
        case .cancelled, .failed: action(.cancelled, point)
        default: break
        }
    }
}
