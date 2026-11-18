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
            BillboardsPanel(model: model, onBack: { page = .sources }, onDone: { dismiss() })
                .sheetChrome()
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
                    HStack(spacing: 6) {
                        ForEach(Meter.allCases, id: \.self) { meter in
                            segment(meter.rawValue, isOn: guide.meter == meter, label: Self.spoken(meter)) {
                                guide.meter = meter
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        segment("♩ Quarter", isOn: guide.subdivision == .quarter) { guide.subdivision = .quarter }
                        segment("♪♪ Eighth", isOn: guide.subdivision == .eighth) { guide.subdivision = .eighth }
                    }
                    // 6/8 already counts eighths.
                    .disabled(guide.meter.isCompound)
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

    /// "Three four time" for VoiceOver.
    static func spoken(_ meter: Meter) -> String {
        let words = ["2": "Two", "3": "Three", "4": "four", "6": "Six", "8": "eight"]
        let parts = meter.rawValue.split(separator: "/").map { words[String($0)] ?? String($0) }
        return "\(parts[0]) \(parts[1].lowercased()) time"
    }

    private func segment(
        _ title: String, isOn: Bool, label: String? = nil, action: @escaping () -> Void
    ) -> some View {
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
        .accessibilityLabel(label ?? title.trimmingCharacters(in: .letters.inverted))
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

// MARK: - Billboards

/// The song you'll add in Instagram, named by hand, with its rhythm captured by tapping along while
/// it plays somewhere else. Nothing of the song is recorded, fetched or copied: the guide is made
/// of your taps. Tap Tempo keeps a steady pulse (its BPM drives a click); Tap Rhythm keeps every
/// tap where it fell, with accents, to correct, quantize (reversibly) and optionally repeat.
private struct BillboardsPanel: View {
    var model: WorkspaceModel
    var onBack: () -> Void
    var onDone: () -> Void

    @State private var song: SongIdentity
    @State private var tappedFromText: String
    @State private var rhythm: TapRhythm
    @State private var capture: TapCapture
    @State private var selected: Int?
    @State private var placement: Placement
    @State private var preview = GuidePreview()
    @State private var isPreviewing = false
    private let replacesGuide: Bool

    init(model: WorkspaceModel, onBack: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.model = model
        self.onBack = onBack
        self.onDone = onDone
        let existing = model.project.referenceAudio?.reference
        let isBillboards = model.project.referenceAudio?.kind == .billboards
        replacesGuide = isBillboards
        let song = (isBillboards ? existing?.song : nil) ?? SongIdentity()
        _song = State(initialValue: song)
        _tappedFromText = State(initialValue: song.tappedFrom.map { MusicSyncNote.clock($0.seconds) } ?? "")
        let rhythm = (isBillboards ? existing?.rhythm : nil) ?? TapRhythm(mode: .tempo)
        _rhythm = State(initialValue: rhythm)
        _capture = State(initialValue: TapCapture(restartAfter: Self.restartGap(rhythm.mode)))
        _placement = State(initialValue: isBillboards ? .keep : .videoStart)
    }

    private static func restartGap(_ mode: TapRhythm.Mode) -> Double {
        mode == .tempo ? TapCapture.restartGap : TapCapture.rhythmRestartGap
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeader(title: "Billboards", onBack: back)
                Text(
                    "Play the song on another device or app and tap along here. Only your taps are kept; nothing of the song is recorded."
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                PanelSection(title: "Song for Instagram") { songFields }
                PanelSection(title: "Capture") { captureControls }
                if rhythm.mode == .rhythm, !rhythm.taps.isEmpty {
                    PanelSection(title: "Rhythm") { rhythmControls }
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
                    .disabled(!canSave)
                    .accessibilityLabel(isPreviewing ? "Stop preview" : "Preview guide")
                    Button {
                        save()
                    } label: {
                        Label("Use this guide", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.instrument(.prominent, height: 52))
                    .disabled(!canSave)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: rhythm) { _, _ in if isPreviewing { startPreview() } }
        .onDisappear { preview.stop() }
    }

    /// Tempo needs a tempo; rhythm needs taps.
    private var canSave: Bool { rhythm.mode == .tempo || !rhythm.taps.isEmpty }

    // MARK: Song

    private var songFields: some View {
        VStack(spacing: 8) {
            field("Title", text: $song.title)
            field("Artist", text: $song.artist)
            field("Section, e.g. the chorus", text: $song.section)
            HStack {
                field("Tapped from (m:ss), optional", text: $tappedFromText)
                    .keyboardType(.numbersAndPunctuation)
                    .onChange(of: tappedFromText) { _, text in song.tappedFrom = Self.songTime(text) }
                if song.tappedFrom != nil {
                    LED(isOn: true).accessibilityLabel("Song position understood")
                }
            }
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Theme.secondaryLabel.opacity(0.7)))
            .font(.system(size: 14))
            .foregroundStyle(Theme.label)
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.45)))
            .accessibilityLabel(prompt)
    }

    /// "1:05.5", "0:42" or "42" → song time; nil when it can't be read.
    static func songTime(_ text: String) -> MediaTime? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard (1...2).contains(parts.count), let last = Double(parts.last!) else { return nil }
        let minutes = parts.count == 2 ? Double(parts[0]) : 0
        guard let minutes, last >= 0, minutes >= 0 else { return nil }
        return MediaTime(value: Int64(((minutes * 60 + last) * 1000).rounded()), timescale: 1000)
    }

    // MARK: Capture

    @ViewBuilder
    private var captureControls: some View {
        HStack(spacing: 8) {
            modeKey("Tap Tempo", .tempo)
            modeKey("Tap Rhythm", .rhythm)
        }
        if rhythm.mode == .tempo {
            HStack(spacing: 10) {
                Button {
                    setBPM(rhythm.grid.bpm.rounded(.up) - 1)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.round(34))
                .accessibilityLabel("Slower")
                VStack(spacing: 0) {
                    Text(bpmText).font(Theme.mono(30, weight: .bold)).foregroundStyle(Theme.signal)
                    Text("BPM").font(Theme.mono(8, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.5)))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tempo \(bpmText) beats per minute")
                Button {
                    setBPM(rhythm.grid.bpm.rounded(.down) + 1)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.round(34))
                .accessibilityLabel("Faster")
            }
            TapPad(title: "Tap tempo", detail: tapDetail) { seconds, _ in tap(seconds, accent: false) }
        } else {
            HStack(spacing: 8) {
                TapPad(title: "Tap", detail: tapDetail) { seconds, _ in tap(seconds, accent: false) }
                TapPad(title: "Accent", detail: "Downbeats, hits", accent: true) { seconds, _ in
                    tap(seconds, accent: true)
                }
                .frame(width: 120)
            }
        }
        Button {
            capture.reset()
            if rhythm.mode == .rhythm { rhythm.taps = [] }
            selected = nil
            Haptics.detent()
        } label: {
            Label("Start over", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
        }
        .buttonStyle(.instrument(height: 34))
        .disabled(capture.times.isEmpty && rhythm.taps.isEmpty)
    }

    private func modeKey(_ title: String, _ mode: TapRhythm.Mode) -> some View {
        Button {
            guard rhythm.mode != mode else { return }
            rhythm.mode = mode
            capture = TapCapture(restartAfter: Self.restartGap(mode))
            selected = nil
            Haptics.detent()
        } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(rhythm.mode == mode ? Theme.signal : Theme.label)
        }
        .buttonStyle(OptionKeyStyle(isOn: rhythm.mode == mode))
    }

    private var tapDetail: String {
        let n = rhythm.mode == .rhythm ? rhythm.taps.count : capture.times.count
        guard n > 0 else {
            return rhythm.mode == .tempo ? "Tap the beat; a pause starts over" : "Tap the rhythm as it plays"
        }
        if rhythm.mode == .tempo, let bpm = capture.bpm { return String(format: "%d taps · %.1f BPM", n, bpm) }
        return "\(n) tap\(n == 1 ? "" : "s")"
    }

    private func tap(_ seconds: Double, accent: Bool) {
        guard capture.tap(at: seconds, accent: accent) else { return }
        switch rhythm.mode {
        case .tempo:
            if let bpm = capture.bpm { rhythm.grid.bpm = (bpm * 10).rounded() / 10 }
        case .rhythm:
            rhythm.taps = capture.rhythm
            selected = nil
        }
    }

    private var bpmText: String {
        let bpm = rhythm.grid.bpm
        return bpm == bpm.rounded() ? String(format: "%.0f", bpm) : String(format: "%.1f", bpm)
    }

    private func setBPM(_ bpm: Double) {
        rhythm.grid.bpm = min(max(bpm, ClickGuide.tempoRange.lowerBound), ClickGuide.tempoRange.upperBound)
        if rhythm.mode == .tempo { capture.reset() }
    }

    // MARK: Rhythm

    @ViewBuilder
    private var rhythmControls: some View {
        RhythmStrip(rhythm: rhythm, selected: $selected)
        if let i = selected, rhythm.taps.indices.contains(i) {
            HStack(spacing: 8) {
                Button("−10 ms") { nudge(i, by: -0.01) }.buttonStyle(.instrument(height: 34))
                    .accessibilityLabel("Tap \(i + 1) 10 milliseconds earlier")
                Button("+10 ms") { nudge(i, by: 0.01) }.buttonStyle(.instrument(height: 34))
                    .accessibilityLabel("Tap \(i + 1) 10 milliseconds later")
                Button(rhythm.taps[i].accent ? "Plain" : "Accent") {
                    rhythm.taps[i].accent.toggle()
                }
                .buttonStyle(.instrument(height: 34))
                Button(role: .destructive) {
                    rhythm.taps.remove(at: i)
                    selected = nil
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.instrument(height: 34))
                .accessibilityLabel("Delete tap \(i + 1)")
            }
        }
        HStack(spacing: 6) {
            Text("GRID").font(Theme.mono(8, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
            Button {
                setBPM(rhythm.grid.bpm.rounded(.up) - 1)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.round(28))
            .accessibilityLabel("Grid slower")
            Text("\(bpmText) BPM").font(Theme.mono(13, weight: .bold)).foregroundStyle(Theme.label)
                .accessibilityLabel("Grid \(bpmText) beats per minute")
            Button {
                setBPM(rhythm.grid.bpm.rounded(.down) + 1)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.round(28))
            .accessibilityLabel("Grid faster")
            Spacer(minLength: 0)
            Button {
                let all = Meter.allCases
                rhythm.grid.meter = all[((all.firstIndex(of: rhythm.grid.meter) ?? 0) + 1) % all.count]
                Haptics.detent()
            } label: {
                Text(rhythm.grid.meter.rawValue).font(Theme.mono(11, weight: .bold))
            }
            .buttonStyle(.instrument(height: 32))
            .accessibilityLabel("Grid meter")
            .accessibilityValue(QuickClickPanel.spoken(rhythm.grid.meter))
            Button {
                rhythm.grid.subdivision = rhythm.grid.subdivision == .quarter ? .eighth : .quarter
                Haptics.detent()
            } label: {
                Text(rhythm.grid.subdivision == .quarter ? "♩ GRID" : "♪ GRID").font(Theme.mono(11, weight: .bold))
            }
            .buttonStyle(.instrument(height: 32))
            .accessibilityLabel(rhythm.grid.subdivision == .quarter ? "Grid in quarters" : "Grid in eighths")
        }
        HStack(spacing: 6) {
            quantizeKey("Human", .human)
            quantizeKey("Light", .light)
            quantizeKey("Snap", .grid)
        }
        Button {
            rhythm.repeats.toggle()
            Haptics.detent()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Repeat the pattern").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(rhythm.repeats ? Theme.signal : Theme.label)
                Text("Loops your taps bar by bar for the whole guide").font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .buttonStyle(OptionKeyStyle(isOn: rhythm.repeats))
    }

    private func quantizeKey(_ title: String, _ q: Quantization) -> some View {
        Button {
            rhythm.quantization = q
            Haptics.detent()
        } label: {
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(rhythm.quantization == q ? Theme.signal : Theme.label)
        }
        .buttonStyle(OptionKeyStyle(isOn: rhythm.quantization == q))
        .accessibilityLabel(q == .human ? "Keep human timing" : q == .light ? "Light quantize" : "Snap to grid")
    }

    private func nudge(_ i: Int, by seconds: Double) {
        let t = max(0, rhythm.taps[i].time.seconds + seconds)
        rhythm.taps[i].time = MediaTime(value: Int64((t * 48_000).rounded()), timescale: 48_000)
        rhythm.taps.sort { $0.time < $1.time }
        Haptics.detent()
    }

    // MARK: Preview and save

    private func startPreview() {
        model.engine.pause()
        let length = rhythm.mode == .rhythm ? rhythm.patternDuration : rhythm.grid.barDuration + rhythm.grid.barDuration
        var looped = rhythm
        looped.repeats = false
        preview.play(looped.clicks(upTo: length), length: length)
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
        let reference = MusicReference(kind: .billboards, rhythm: rhythm, song: song.isEmpty ? nil : song)
        let title = song.title.trimmingCharacters(in: .whitespaces)
        let name = title.isEmpty ? "Billboards guide" : "Billboards: \(title)"
        let at = placement.time(model)
        Task { await model.saveGuide(reference, named: name, beatOneAt: at) }
        onDone()
    }
}

/// The captured taps against the grid: bar lines, beat lines and each tap as a marker (accents
/// taller), as placed by the current quantizing. Tap a marker to select it for correction.
private struct RhythmStrip: View {
    var rhythm: TapRhythm
    @Binding var selected: Int?

    /// Seconds the strip spans: the whole pattern.
    private var length: Double { max(rhythm.patternDuration.seconds, 0.5) }

    var body: some View {
        GeometryReader { geo in
            let scale = Double(geo.size.width) / length
            Canvas { context, size in draw(in: &context, size: size, scale: scale) }
                .contentShape(Rectangle())
                .onTapGesture { location in select(near: Double(location.x) / scale) }
        }
        .frame(height: 54)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.5)))
        .accessibilityElement()
        .accessibilityLabel("Rhythm, \(rhythm.taps.count) taps")
        .accessibilityValue(selected.map { "Tap \($0 + 1) selected" } ?? "")
        .accessibilityAdjustableAction { direction in
            let count = rhythm.taps.count
            guard count > 0 else { return }
            let i = selected ?? -1
            selected = direction == .increment ? min(i + 1, count - 1) : max(i - 1, 0)
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, scale: Double) {
        let beat = 60 / rhythm.grid.bpm
        var k = 0
        while Double(k) * beat <= length + 1e-6 {
            let x = CGFloat(Double(k) * beat * scale)
            let isBar = k % rhythm.grid.beatsPerBar == 0
            let line = CGRect(x: x, y: 0, width: isBar ? 1.5 : 0.75, height: size.height)
            context.fill(Path(line), with: .color(Theme.ivory.opacity(isBar ? 0.4 : 0.15)))
            k += 1
        }
        for (i, tap) in rhythm.placedTaps.enumerated() {
            let x = CGFloat(tap.time.seconds * scale)
            let h: CGFloat = tap.accent ? size.height - 6 : size.height * 0.55
            let marker = CGRect(x: x - 2, y: size.height - h - 3, width: 4, height: h)
            context.fill(
                Path(roundedRect: marker, cornerRadius: 2), with: .color(i == selected ? Theme.ivory : Theme.signal))
        }
    }

    /// Selects the tap nearest `seconds` (or clears it, tapped again).
    private func select(near seconds: Double) {
        let placed = rhythm.placedTaps
        let nearest = placed.indices.min {
            abs(placed[$0].time.seconds - seconds) < abs(placed[$1].time.seconds - seconds)
        }
        selected = nearest == selected ? nil : nearest
        Haptics.detent()
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
