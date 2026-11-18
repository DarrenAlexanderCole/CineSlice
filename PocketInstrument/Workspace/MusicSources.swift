import EditCore
import SwiftUI

/// Where the reference music comes from, opened from Mix's music key: three choices in order.
/// **My Music** is a song on the phone (Files, or a video's sound), the existing import.
/// **Quick Click** builds a click guide at a chosen tempo, with no song needed.
/// **Billboards** names the song to add in Instagram later and captures its rhythm by tapping
/// along to it played elsewhere; nothing of the song itself is copied.
/// Whatever is chosen becomes the project's one reference track, undoable like any edit.
struct MusicSourceSheet: View {
    var model: WorkspaceModel
    /// Asks for a system picker; it opens once this sheet has gone, since two can't be up at once.
    var onPick: (Pick) -> Void

    enum Pick { case files, video }

    enum Page { case sources, quickClick, billboards }

    @State private var page = Page.sources
    @State private var showsMyMusic = false
    @Environment(\.dismiss) private var dismiss

    private var current: MusicReference.Kind? { model.project.referenceAudio?.kind }

    var body: some View {
        switch page {
        case .sources: sources
        case .quickClick:
            QuickClickPanel(model: model, onBack: { page = .sources }, onDone: { dismiss() })
                .sheetChrome()
        case .billboards:
            sources
        }
    }

    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TitlePlate(title: "Music", subtitle: "A reference to cut against")
                PanelSection(title: "Choose a source") {
                    myMusic
                    choice(
                        2, "Quick Click", "A click guide at your tempo. No song needed.", icon: "metronome",
                        isOn: current == .quickClick
                    ) { page = .quickClick }
                    choice(
                        3, "Billboards", "Name the song you'll add in Instagram and tap its rhythm.",
                        icon: "music.quarternote.3", isOn: current == .billboards
                    ) { page = .billboards }
                    .disabled(true)
                }
                if model.project.referenceAudio != nil {
                    Button(role: .destructive) {
                        model.removeMusic()
                        dismiss()
                    } label: {
                        Label("Remove music", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.instrument(height: 40))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .sheetChrome()
    }

    private var hasSong: Bool { model.project.referenceAudio != nil }

    /// My Music opens to its sources in place: Files, a video's sound, or the demo click.
    @ViewBuilder
    private var myMusic: some View {
        choice(
            1, "My Music", "A song on this iPhone: from Files, or the sound of a video.", icon: "music.note.list",
            isOn: showsMyMusic || current == .myMusic
        ) {
            withAnimation(.easeOut(duration: 0.2)) { showsMyMusic.toggle() }
        }
        if showsMyMusic {
            HStack(spacing: 8) {
                Button {
                    pick(.files)
                } label: {
                    Label(hasSong ? "Replace from Files" : "Files", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.instrument(.key, height: 40))
                .accessibilityLabel(hasSong ? "Replace from Files" : "Song from Files")
                Button {
                    pick(.video)
                } label: {
                    Label("From a video", systemImage: "film").frame(maxWidth: .infinity)
                }
                .buttonStyle(.instrument(height: 40))
                .accessibilityLabel("Sound from a video")
            }
            Button {
                Task { await model.addDemoClickTrack() }
                dismiss()
            } label: {
                Label("Demo click track", systemImage: "waveform").frame(maxWidth: .infinity)
            }
            .buttonStyle(.instrument(height: 34))
            .accessibilityHint("Generates a 30 second, 120 BPM metronome for testing sync")
        }
    }

    private func pick(_ source: Pick) {
        onPick(source)
        dismiss()
    }

    /// One source as a wide key: its number, an icon, a title and a line of detail.
    private func choice(
        _ number: Int, _ title: String, _ detail: String, icon: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            Haptics.detent()
        } label: {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(Theme.mono(11, weight: .bold))
                    .foregroundStyle(isOn ? Theme.signal : Theme.secondaryLabel)
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isOn ? Theme.signal : Theme.ivory)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isOn ? Theme.signal : Theme.label)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(OptionKeyStyle(isOn: isOn))
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

extension View {
    /// The music sheet's chassis and corners.
    fileprivate func sheetChrome() -> some View {
        self.presentationBackground { Chassis(cornerRadius: 0) }
            .presentationCornerRadius(26)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Quick Click

/// A click guide without a song: tempo (typed with −/+, dragged on the readout, or tapped),
/// 4/4, quarter or eighth clicks, an accented beat one, and where beat one goes. It previews on
/// a loop, then renders as the reference track (one undoable step). After that it lines up in
/// Mix like any song: drag or nudge it, and lock it.
private struct QuickClickPanel: View {
    var model: WorkspaceModel
    var onBack: () -> Void
    var onDone: () -> Void

    @State private var guide: ClickGuide
    @State private var capture = TapCapture()
    @State private var placement: Placement
    @State private var preview = GuidePreview()
    @State private var isPreviewing = false
    @State private var dragBase: Double?
    private let replacesGuide: Bool

    init(model: WorkspaceModel, onBack: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.model = model
        self.onBack = onBack
        self.onDone = onDone
        let existing = model.project.referenceAudio?.reference?.click
        let isClick = model.project.referenceAudio?.kind == .quickClick
        replacesGuide = isClick
        _guide = State(initialValue: existing ?? ClickGuide())
        _placement = State(initialValue: isClick ? .keep : .videoStart)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "Quick Click", onBack: back)
                PanelSection(title: "Tempo") {
                    tempo
                    TapPad(title: "Tap tempo", detail: tapDetail) { seconds, _ in
                        capture.tap(at: seconds)
                        if let bpm = capture.bpm { guide.bpm = (bpm * 10).rounded() / 10 }
                    }
                }
                PanelSection(title: "Meter") {
                    HStack(spacing: 8) {
                        VStack(spacing: 2) {
                            Text("TIME").font(Theme.mono(8, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
                            Text("4/4").font(Theme.mono(16, weight: .bold)).foregroundStyle(Theme.label)
                        }
                        .frame(width: 56)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Four four time")
                        segment("♩ Quarter", isOn: guide.subdivision == .quarter) { guide.subdivision = .quarter }
                        segment("♪♪ Eighth", isOn: guide.subdivision == .eighth) { guide.subdivision = .eighth }
                    }
                    segment("Accent beat one of each bar", isOn: guide.accentsDownbeat) {
                        guide.accentsDownbeat.toggle()
                    }
                }
                PanelSection(title: "Beat one") {
                    PlacementPicker(model: model, placement: $placement, canKeep: replacesGuide)
                }
                HStack(spacing: 10) {
                    Button {
                        isPreviewing ? stopPreview() : startPreview()
                    } label: {
                        Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.round(46, lit: isPreviewing))
                    .accessibilityLabel(isPreviewing ? "Stop preview" : "Preview click")
                    Button {
                        save()
                    } label: {
                        Label("Use this click", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.instrument(.prominent, height: 52))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .onChange(of: guide) { _, _ in if isPreviewing { startPreview() } }
        .onDisappear { preview.stop() }
    }

    private var tapDetail: String {
        let n = capture.times.count
        guard n > 0 else { return "Tap along to the beat; a pause starts over" }
        return capture.bpm.map { String(format: "%d taps · %.1f BPM", n, $0) }
            ?? "\(n) tap\(n == 1 ? "" : "s") · keep going"
    }

    /// The tempo, big and lit: −/+ step it a beat per minute; dragging across it fine-tunes.
    private var tempo: some View {
        HStack(spacing: 10) {
            Button {
                setBPM(guide.bpm.rounded(.up) - 1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.round(38))
            .accessibilityLabel("Slower")
            VStack(spacing: 0) {
                Text(bpmText)
                    .font(Theme.mono(40, weight: .bold))
                    .foregroundStyle(Theme.signal)
                    .shadow(color: Theme.signal.opacity(0.5), radius: 6)
                    .contentTransition(.numericText())
                Text("BPM · DRAG TO FINE-TUNE").font(Theme.mono(8, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
            }
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.5)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { g in
                        let base = dragBase ?? guide.bpm
                        dragBase = base
                        let next = (base + Double(g.translation.width / 6)).rounded()
                        if next != guide.bpm.rounded() { Haptics.detent() }
                        setBPM(next)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Tempo")
            .accessibilityValue("\(bpmText) beats per minute")
            .accessibilityAdjustableAction { direction in
                setBPM(guide.bpm.rounded() + (direction == .increment ? 1 : -1))
            }
            Button {
                setBPM(guide.bpm.rounded(.down) + 1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.round(38))
            .accessibilityLabel("Faster")
        }
    }

    private var bpmText: String {
        guide.bpm == guide.bpm.rounded() ? String(format: "%.0f", guide.bpm) : String(format: "%.1f", guide.bpm)
    }

    private func setBPM(_ bpm: Double) {
        guide.bpm = min(max(bpm, ClickGuide.tempoRange.lowerBound), ClickGuide.tempoRange.upperBound)
        capture.reset()
    }

    private func segment(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            Haptics.detent()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Theme.signal : Theme.label)
        }
        .buttonStyle(OptionKeyStyle(isOn: isOn))
        // Read without the note symbols.
        .accessibilityLabel(title.trimmingCharacters(in: .letters.inverted))
    }

    private func startPreview() {
        model.engine.pause()
        let length = guide.barDuration + guide.barDuration
        preview.play(guide.clicks(upTo: length), length: length)
        isPreviewing = true
    }

    private func stopPreview() {
        preview.stop()
        isPreviewing = false
    }

    private func back() {
        stopPreview()
        onBack()
    }

    private func save() {
        stopPreview()
        let reference = MusicReference(kind: .quickClick, click: guide)
        let name = "Quick Click \(bpmText) BPM"
        let at = placement.time(model)
        Task { await model.saveGuide(reference, named: name, beatOneAt: at) }
        onDone()
    }
}

// MARK: - Shared parts

/// Where a new guide's beat one goes on the timeline.
enum Placement: Hashable {
    /// Re-saving: where the guide already sits.
    case keep
    case videoStart
    case playhead

    /// The composition time to put beat one at; nil keeps it where it is.
    @MainActor
    func time(_ model: WorkspaceModel) -> MediaTime? {
        switch self {
        case .keep: nil
        case .videoStart: .zero
        case .playhead: model.currentTime
        }
    }
}

private struct PlacementPicker: View {
    var model: WorkspaceModel
    @Binding var placement: Placement
    var canKeep: Bool

    var body: some View {
        if canKeep { row("Keep where it is", "As lined up in Mix", .keep) }
        row("At the start of the video", "Then drag or nudge it in Mix", .videoStart)
        row(
            "At the playhead · \(MusicSyncNote.clock(model.currentTime.seconds))",
            "Park the playhead on the first cut before opening Music", .playhead)
    }

    private func row(_ title: String, _ detail: String, _ value: Placement) -> some View {
        Button {
            placement = value
            Haptics.detent()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(placement == value ? Theme.signal : Theme.label)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondaryLabel)
            }
        }
        .buttonStyle(OptionKeyStyle(isOn: placement == value))
    }
}

/// A panel's back key and stamped name.
struct PanelHeader: View {
    var title: String
    var onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Label("Sources", systemImage: "chevron.left")
            }
            .buttonStyle(.instrument(height: 32))
            Spacer()
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .serif).italic())
                .foregroundStyle(Theme.ivory)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// A wide pad to tap along to music. It reads each touch's own timestamp (the system's monotonic
/// clock, from the hardware), not the time the screen next redraws, so taps keep their real
/// spacing. VoiceOver users double-tap it, timed by the same clock.
struct TapPad: View {
    var title: String
    var detail: String
    var accent = false
    /// Seconds on the monotonic clock, and whether it's the accent pad.
    var onTap: (Double, Bool) -> Void

    @State private var flash = false

    var body: some View {
        ZStack {
            KeyCap(kind: accent ? .key : .dark, isLit: flash, isPressed: flash)
            VStack(spacing: 2) {
                Text(title.uppercased())
                    .font(Theme.mono(13, weight: .heavy))
                    .foregroundStyle(accent ? Theme.obsidian : (flash ? Theme.signal : Theme.ivory))
                Text(detail).font(.system(size: 11))
                    .foregroundStyle(accent ? Theme.obsidian.opacity(0.7) : Theme.secondaryLabel)
            }
            .allowsHitTesting(false)
            TouchTimestamps { seconds in
                onTap(seconds, accent)
                Haptics.press()
                flash = true
                Task {
                    try? await Task.sleep(for: .milliseconds(90))
                    flash = false
                }
            }
        }
        .frame(height: 64)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(detail)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap(ProcessInfo.processInfo.systemUptime, accent) }
    }
}

/// Reports each touch-down's timestamp: `UITouch.timestamp`, seconds since boot.
private struct TouchTimestamps: UIViewRepresentable {
    var onTouch: (Double) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isMultipleTouchEnabled = true
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) { view.onTouch = onTouch }

    final class TouchView: UIView {
        var onTouch: ((Double) -> Void)?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for touch in touches.sorted(by: { $0.timestamp < $1.timestamp }) { onTouch?(touch.timestamp) }
        }
    }
}
