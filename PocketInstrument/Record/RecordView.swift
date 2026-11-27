import AVFoundation
import EditCore
import SwiftUI
import UniformTypeIdentifiers

/// The Record page: the camera's live picture behind a metal cap, a backlit counter, the mode
/// keys (video, photo, sound) and the shutter. Every take, sound too, goes into the bin's TAKES
/// folder as soon as it stops, to put on the timeline from there. The page stays open for more
/// takes until Done. Upright, the keys sit under the picture; held sideways,
/// in a column beside it. Two rings work the camera by hand: across the screen under the
/// picture upright, stood up on its left held sideways, where the left hand works them like a
/// lens. Their pages: LENS (zoom, focus), EXPO (shutter, then ISO by hand or exposure
/// compensation on automatic) and WB (colour temperature, tint), with the frame rate beside
/// them. In the picture's corner: the camera's settings, the look (shot through, shown live and
/// kept on every take) and a live RGB histogram of the picture through it; each taps or swipes
/// down out of the way. Sound mode's screen is a small recorder desk (`SoundDesk`).
struct RecordView: View {
    var model: WorkspaceModel
    var onDone: () -> Void

    @State private var rig: CameraRig
    /// Where the picture was last tapped to focus, shown for a moment.
    @State private var focusMark: CGPoint?
    @State private var showsCubeImport = false
    @AppStorage("record.ringPage") private var ringPage = RingPage.lens
    /// The look last shot with, so the next visit starts with it.
    @AppStorage("record.look") private var savedLook = Data()

    init(model: WorkspaceModel, mode: CameraRig.Mode, onDone: @escaping () -> Void) {
        self.model = model
        self.onDone = onDone
        _rig = State(initialValue: CameraRig(mode: mode))
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(spacing: 12))
            layout {
                if wide, showsRings { rings(vertical: true).frame(width: 92) }
                VStack(spacing: 10) {
                    screen
                        .metalBezel(cornerRadius: 14, width: 5)
                        .overlay(alignment: .top) { counter.padding(.top, 14) }
                    // Sound mode's EQ on its own plate under the screen, where the rings sit.
                    if showsEQ { EQFaceplate(recorder: rig.sound).frame(height: wide ? 130 : 176) }
                }
                if !wide, showsRings { rings(vertical: false).frame(height: 106) }
                controls(wide: wide)
                    .frame(width: wide ? 132 : nil, height: wide ? nil : 190)
            }
            .padding(.horizontal, wide ? 12 : 10)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.2), value: showsRings)
            .animation(.easeInOut(duration: 0.2), value: showsEQ)
        }
        .background(Theme.obsidian.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            model.beginRecording()
            rig.onTake = { take in Task { await model.addTake(take) } }
            rig.onError = { model.alertMessage = $0 }
            if let look = try? JSONDecoder().decode(Look.self, from: savedLook), LookLibrary.cube(for: look) != nil {
                rig.setLook(look)
            }
            await rig.start()
        }
        .onDisappear { rig.stop() }
        .onChange(of: rig.look) { _, look in
            savedLook = look.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        }
        .fileImporter(
            isPresented: $showsCubeImport, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            do {
                rig.setLook(try LookLibrary.importCube(from: url))
            } catch {
                model.alertMessage = "That look couldn't be imported. \(error.localizedDescription)"
            }
        }
    }

    // MARK: Screen

    @ViewBuilder
    private var screen: some View {
        ZStack {
            Color.black
            if rig.mode == .sound {
                SoundDesk(recorder: rig.sound, isRecording: rig.isRecording, access: rig.micAccess)
            } else if rig.cameraAccess == .denied {
                notice(
                    "Camera access is off", "Turn it on in Settings to record video and photos here.", settings: true)
            } else if !rig.hasCamera {
                notice("No camera", "This device has no camera to record with. Sound still works.", settings: false)
            } else {
                CameraPreview(rig: rig)
                    .overlay {
                        // The picture through the look, over the plain one; taps go through.
                        if rig.canShowLooks {
                            LookPreview(rig: rig).opacity(rig.look == nil ? 0 : 1).allowsHitTesting(false)
                        }
                    }
                    .onTapGesture { point in
                        rig.focus(atLayerPoint: point)
                        focusMark = point
                        Haptics.tap()
                    }
                    .overlay(alignment: .topLeading) { focusSquare }
                if rig.flash { Color.white.opacity(0.7).allowsHitTesting(false) }
                HStack(alignment: .bottom, spacing: 6) {
                    CameraReadout(rig: rig) { showsCubeImport = true }
                    ScopeCorner(rig: rig)
                }
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            if let status = model.importStatus {
                VStack(alignment: .leading) {
                    Spacer()
                    HStack(spacing: 6) {
                        ProgressView().tint(Theme.signal).controlSize(.mini)
                        Text(status.uppercased()).font(Theme.mono(9, weight: .bold)).foregroundStyle(Theme.label)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(10)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Lens rings

    private var showsEQ: Bool { rig.mode == .sound && rig.micAccess != .denied }

    private var showsRings: Bool { rig.mode != .sound && rig.cameraAccess == .granted && rig.hasCamera }

    enum RingPage: String, CaseIterable {
        case lens = "LENS"
        case exposure = "EXPO"
        case balance = "WB"
    }

    private func rings(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
        return VStack(spacing: 6) {
            pageKeys(vertical: vertical)
            layout {
                switch ringPage {
                case .lens:
                    ringRow(
                        "ZOOM", String(format: "%.1f×", rig.zoom), vertical: vertical,
                        ring: zoomRing(vertical: vertical))
                    ringRow(
                        "FOCUS", focusReadout, vertical: vertical, ring: focusRing(vertical: vertical),
                        key: PlateKey(
                            active: !rig.isAutoFocus, enabled: rig.canFocus, label: "Manual focus",
                            hint: "Turn the ring to focus by hand. Off, the camera focuses itself."
                        ) { rig.toggleManualFocus() })
                case .exposure:
                    ringRow(
                        rig.isAutoExposure ? "AE" : "SHUTTER", shutterReadout, vertical: vertical,
                        ring: shutterRing(vertical: vertical),
                        key: PlateKey(
                            active: !rig.isAutoExposure, enabled: rig.canExpose, label: "Manual exposure",
                            hint: "On, the shutter and ISO hold where you set them. Off, the camera exposes itself."
                        ) { rig.toggleAutoExposure() })
                    if rig.isAutoExposure {
                        ringRow(
                            "EV", evReadout, vertical: vertical, ring: evRing(vertical: vertical),
                            key: PlateKey(
                                active: rig.exposureBias != 0, enabled: rig.exposureBias != 0,
                                label: "Exposure compensation", hint: "Back to the camera's own exposure."
                            ) { rig.setExposureBias(0) })
                    } else {
                        ringRow(
                            "ISO", "\(Int(rig.iso.rounded()))", vertical: vertical, ring: isoRing(vertical: vertical))
                    }
                case .balance:
                    ringRow(
                        rig.isAutoWhiteBalance ? "AWB" : "WB", kelvinReadout, vertical: vertical,
                        ring: kelvinRing(vertical: vertical),
                        key: PlateKey(
                            active: !rig.isAutoWhiteBalance, enabled: rig.canBalance, label: "Manual white balance",
                            hint: "On, the colour holds where you set it. Off, the camera balances itself."
                        ) { rig.toggleAutoWhiteBalance() })
                    ringRow(
                        "TINT", tintReadout, vertical: vertical, ring: tintRing(vertical: vertical),
                        key: PlateKey(
                            active: rig.tint != 0 && !rig.isAutoWhiteBalance,
                            enabled: rig.tint != 0 && !rig.isAutoWhiteBalance, label: "Tint",
                            hint: "Back to no tint."
                        ) { rig.setWhiteBalance(tint: 0) })
                }
            }
        }
    }

    /// The ring pages, and the frame rate while shooting video.
    private func pageKeys(vertical: Bool) -> some View {
        let keys = HStack(spacing: 4) {
            ForEach(RingPage.allCases, id: \.self) { page in
                Button {
                    ringPage = page
                    Haptics.detent()
                } label: {
                    Text(page.rawValue).font(Theme.mono(8, weight: .bold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.instrument(.dark, active: ringPage == page, height: 22))
                .accessibilityAddTraits(ringPage == page ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Camera controls")
        return Group {
            if vertical {
                VStack(spacing: 4) {
                    keys
                    if rig.mode == .video { frameRateMenu }
                }
            } else {
                HStack(spacing: 4) {
                    keys
                    if rig.mode == .video { frameRateMenu.frame(width: 72) }
                }
            }
        }
    }

    private var frameRateMenu: some View {
        Menu {
            ForEach(rig.frameRates, id: \.self) { rate in
                Button {
                    rig.setFrameRate(rate)
                } label: {
                    if rate == rig.frameRate {
                        Label("\(rate) fps", systemImage: "checkmark")
                    } else {
                        Text("\(rate) fps")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("\(rig.frameRate) FPS").font(Theme.mono(8, weight: .bold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(LensRing.engraving)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.black.opacity(0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        }
        .disabled(rig.isRecording)
        .accessibilityLabel("Frame rate")
        .accessibilityValue("\(rig.frameRate) frames a second")
    }

    /// A ring's name plate as a key: manual or automatic, or back to zero.
    private struct PlateKey {
        let active: Bool
        let enabled: Bool
        let label: String
        let hint: String
        let action: () -> Void
    }

    /// A ring with its name and reading beside it. With a `key`, the name plate is a key.
    private func ringRow(_ title: String, _ readout: String, vertical: Bool, ring: LensRing, key: PlateKey? = nil)
        -> some View
    {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        let plate = VStack(spacing: 1) {
            Text(title).font(Theme.mono(7, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
            Text(readout).font(Theme.mono(10, weight: .bold)).foregroundStyle(LensRing.engraving)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        return layout {
            if let key {
                Button(action: key.action) { plate.frame(width: 44) }
                    .buttonStyle(.instrument(.dark, active: key.active, height: 34))
                    .frame(width: 48)
                    .disabled(!key.enabled)
                    .accessibilityLabel(key.label)
                    .accessibilityValue(key.active ? "On" : "Off")
                    .accessibilityHint(key.hint)
            } else {
                plate.frame(width: 48).accessibilityHidden(true)
            }
            ring
        }
    }

    /// A small square where the picture was tapped to focus, fading after a moment.
    @ViewBuilder
    private var focusSquare: some View {
        if let focusMark {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(LensRing.engraving, lineWidth: 1.5)
                .frame(width: 64, height: 64)
                .offset(x: focusMark.x - 32, y: focusMark.y - 32)
                .allowsHitTesting(false)
                .transition(.opacity)
                .task(id: focusMark) {
                    try? await Task.sleep(for: .milliseconds(900))
                    withAnimation { self.focusMark = nil }
                }
        }
    }

    /// Zoom on a doubling scale, so 0.5×, 1×, 2× sit evenly round the ring.
    private func zoomRing(vertical: Bool) -> LensRing {
        let range = log2(rig.zoomRange.lowerBound)...log2(rig.zoomRange.upperBound)
        let labelled = rig.zoomMarks.map { LensRing.Mark(position: log2($0), label: Self.zoomLabel($0)) }
        let between = stride(from: (range.lowerBound * 4).rounded(.up) / 4, through: range.upperBound, by: 0.25)
            .filter { position in !labelled.contains { abs($0.position - position) < 0.1 } }
            .map { LensRing.Mark(position: $0, label: nil) }
        return LensRing(
            title: "Zoom", readout: String(format: "%.1f times", rig.zoom), marks: labelled + between, range: range,
            degreesPerUnit: 40, value: log2(rig.zoom), vertical: vertical,
            onChange: { rig.setZoom(pow(2, $0)) },
            onEnd: { position in
                // Lets go close to an engraved stop and it settles on it.
                if let stop = labelled.first(where: { abs($0.position - position) < 0.08 }) {
                    rig.setZoom(pow(2, stop.position))
                }
            })
    }

    private static func zoomLabel(_ zoom: Double) -> String {
        if zoom < 1 { return String(format: ".%.0f", zoom * 10) }
        return zoom == zoom.rounded() ? "\(Int(zoom))" : String(format: "%.1f", zoom)
    }

    /// Focus from AF, past the lens's nearest, out to its farthest.
    private func focusRing(vertical: Bool) -> LensRing {
        var marks = [
            LensRing.Mark(position: CameraRig.autoFocusDial, label: "AF"),
            LensRing.Mark(position: 0, label: "MIN"),
            LensRing.Mark(position: 1, label: "∞"),
        ]
        marks += stride(from: 0.1, to: 1, by: 0.1).map { LensRing.Mark(position: $0, label: nil) }
        return LensRing(
            title: "Focus", readout: rig.isAutoFocus ? "Automatic" : focusReadout, marks: marks,
            range: CameraRig.autoFocusDial...1, degreesPerUnit: 100, value: rig.focusDial, vertical: vertical,
            enabled: rig.canFocus,
            onChange: { rig.turnFocus(to: $0) },
            onEnd: { _ in rig.settleFocus() })
    }

    private var focusReadout: String {
        rig.isAutoFocus ? "AF" : String(format: "%.0f%%", max(0, rig.focusDial) * 100)
    }

    // MARK: Exposure and colour rings

    /// The shutter as the camera has it: set by hand, or the camera's own on automatic.
    private var shownShutter: Double { rig.isAutoExposure ? rig.cameraData.shutter : rig.shutterSpeed }

    private var shutterReadout: String {
        let seconds = shownShutter
        guard seconds > 0 else { return "1/–" }
        return seconds >= 1 ? String(format: "%.1fs", seconds) : "1/\(Int((1 / seconds).rounded()))"
    }

    /// The shutter on a doubling scale of its speed, so each stop is the same turn; faster to
    /// the right. On automatic it turns by itself as the camera exposes, and turning it takes
    /// exposure by hand.
    private func shutterRing(vertical: Bool) -> LensRing {
        let range = log2(1 / rig.longestShutter)...log2(1 / rig.shutterRange.lowerBound)
        let labelled: [(Double, String)] = [
            (24, "24"), (30, "30"), (48, "48"), (60, "60"), (125, "125"), (250, "250"), (500, "500"),
            (1000, "1K"), (2000, "2K"), (4000, "4K"), (8000, "8K"),
        ]
        var marks = labelled.map { LensRing.Mark(position: log2($0.0), label: $0.1) }
        marks += [25.0, 50, 100].map { LensRing.Mark(position: log2($0), label: nil) }
        marks = marks.filter { range.contains($0.position) }
        let value = shownShutter > 0 ? log2(1 / shownShutter) : range.lowerBound
        return LensRing(
            title: "Shutter", readout: shutterReadout, marks: marks, range: range, degreesPerUnit: 40,
            value: min(range.upperBound, max(range.lowerBound, value)), vertical: vertical, enabled: rig.canExpose,
            onChange: { rig.setShutter(1 / pow(2, $0)) },
            onEnd: { position in
                // 1/48, 1/50, 1/60 and the rest catch as it's let go near them.
                if let stop = marks.min(by: { abs($0.position - position) < abs($1.position - position) }),
                    abs(stop.position - position) < 0.06
                {
                    rig.setShutter(1 / pow(2, stop.position))
                }
            })
    }

    private func isoRing(vertical: Bool) -> LensRing {
        let range = Double(log2(rig.isoRange.lowerBound))...Double(log2(rig.isoRange.upperBound))
        var marks = [25.0, 50, 100, 200, 400, 800, 1600, 3200, 6400, 12800].map {
            LensRing.Mark(position: log2($0), label: $0 >= 10_000 ? "\(Int($0 / 1000))K" : "\(Int($0))")
        }
        marks += stride(from: (range.lowerBound * 3).rounded(.up) / 3, through: range.upperBound, by: 1.0 / 3)
            .filter { position in !marks.contains { abs($0.position - position) < 0.1 } }
            .map { LensRing.Mark(position: $0, label: nil) }
        marks = marks.filter { range.contains($0.position) }
        return LensRing(
            title: "ISO", readout: "\(Int(rig.iso.rounded()))", marks: marks, range: range, degreesPerUnit: 30,
            value: Double(log2(max(1, rig.iso))), vertical: vertical, enabled: rig.canExpose,
            onChange: { rig.setISO(Float(pow(2, $0))) },
            onEnd: { position in
                if let stop = marks.first(where: { abs($0.position - position) < 0.06 }) {
                    rig.setISO(Float(pow(2, stop.position)))
                }
            })
    }

    private var evReadout: String {
        abs(rig.exposureBias) < 0.05 ? "0.0" : String(format: "%+.1f", rig.exposureBias)
    }

    /// Exposure compensation in stops, in thirds, while exposure is automatic.
    private func evRing(vertical: Bool) -> LensRing {
        let range = Double(rig.biasRange.lowerBound)...Double(rig.biasRange.upperBound)
        let marks = stride(from: (range.lowerBound * 3).rounded(.up) / 3, through: range.upperBound, by: 1.0 / 3)
            .map { position -> LensRing.Mark in
                let whole = abs(position - position.rounded()) < 0.01
                let n = Int(position.rounded())
                return LensRing.Mark(position: position, label: whole ? (n > 0 ? "+\(n)" : "\(n)") : nil)
            }
        return LensRing(
            title: "Exposure compensation", readout: evReadout + " stops", marks: marks, range: range,
            degreesPerUnit: 34, value: Double(rig.exposureBias), vertical: vertical,
            onChange: { rig.setExposureBias(Float($0)) },
            onEnd: { rig.setExposureBias(Float(($0 * 3).rounded() / 3)) })
    }

    private var shownKelvin: Float { rig.isAutoWhiteBalance ? rig.cameraData.kelvin : rig.kelvin }

    private var kelvinReadout: String {
        shownKelvin > 0 ? "\(Int((shownKelvin / 100).rounded()) * 100)K" : "AWB"
    }

    /// Colour temperature in thousands of kelvin, tungsten to shade. On automatic it follows the
    /// camera; turning it holds the white balance.
    private func kelvinRing(vertical: Bool) -> LensRing {
        let range = Double(CameraRig.kelvinRange.lowerBound / 1000)...Double(CameraRig.kelvinRange.upperBound / 1000)
        var marks = [2.5, 3.2, 4.3, 5.6, 7.5, 9].map {
            LensRing.Mark(position: $0, label: "\(Int($0 * 1000))")
        }
        marks += stride(from: 3.0, through: 8.5, by: 0.5)
            .filter { position in !marks.contains { abs($0.position - position) < 0.2 } }
            .map { LensRing.Mark(position: $0, label: nil) }
        let value = Double(shownKelvin > 0 ? shownKelvin : 5600) / 1000
        return LensRing(
            title: "White balance", readout: kelvinReadout, marks: marks, range: range, degreesPerUnit: 36,
            value: min(range.upperBound, max(range.lowerBound, value)), vertical: vertical, enabled: rig.canBalance,
            onChange: { rig.setWhiteBalance(kelvin: Float($0 * 1000)) },
            onEnd: { position in
                // 3200 and 5600 and the other engraved stops catch.
                if let stop = marks.first(where: { $0.label != nil && abs($0.position - position) < 0.08 }) {
                    rig.setWhiteBalance(kelvin: Float(stop.position * 1000))
                }
            })
    }

    private var tintReadout: String {
        guard !rig.isAutoWhiteBalance, abs(rig.tint) >= 0.5 else { return "0" }
        return rig.tint < 0 ? "G\(Int(-rig.tint.rounded()))" : "M\(Int(rig.tint.rounded()))"
    }

    /// Tint, green to magenta, in tens.
    private func tintRing(vertical: Bool) -> LensRing {
        let marks = stride(from: -5.0, through: 5.0, by: 0.5).map { position -> LensRing.Mark in
            let labels: [Double: String] = [-5: "G50", -2.5: "G25", 0: "0", 2.5: "M25", 5: "M50"]
            return LensRing.Mark(position: position, label: labels[position])
        }
        return LensRing(
            title: "Tint", readout: tintReadout, marks: marks, range: -5...5, degreesPerUnit: 20,
            value: rig.isAutoWhiteBalance ? 0 : Double(rig.tint / 10), vertical: vertical, enabled: rig.canBalance,
            onChange: { rig.setWhiteBalance(tint: Float($0 * 10)) },
            onEnd: { position in
                if abs(position) < 0.15 { rig.setWhiteBalance(tint: 0) }
            })
    }

    private func notice(_ title: String, _ detail: String, settings: Bool) -> some View {
        VStack(spacing: 10) {
            Text(title.uppercased()).font(Theme.mono(11, weight: .bold)).foregroundStyle(Theme.label)
            Text(detail).font(.footnote).foregroundStyle(Theme.secondaryLabel).multilineTextAlignment(.center)
            if settings, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }
                    .buttonStyle(.instrument(.key, height: 36))
                    .frame(width: 160)
            }
        }
        .padding(24)
    }

    /// The take's running time while recording, lit; dark and zero otherwise.
    private var counter: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
            let elapsed = rig.recordingStarted.map { context.date.timeIntervalSince($0) } ?? 0
            HStack(spacing: 6) {
                Circle()
                    .fill(rig.isRecording ? Theme.playhead : Theme.playhead.opacity(0.25))
                    .frame(width: 7, height: 7)
                TimecodeText(
                    time: MediaTime(seconds: elapsed), frameRate: 30, size: 13,
                    color: rig.isRecording ? Color(hex: 0xFFB54A) : Color(hex: 0xFFB54A).opacity(0.4))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.65)))
        }
        .accessibilityElement()
        .accessibilityLabel(rig.isRecording ? "Recording" : "Ready")
    }

    // MARK: Controls

    private func controls(wide: Bool) -> some View {
        let stack = wide ? AnyLayout(VStackLayout(spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
        return stack {
            modeKeys(wide: wide)
            HStack(spacing: 0) {
                if !wide { takesKey.frame(maxWidth: .infinity) }
                ShutterKey(mode: rig.mode, isRecording: rig.isRecording, enabled: canShoot) { rig.shutter() }
                    .frame(maxWidth: wide ? .infinity : nil)
                if !wide { flipKey.frame(maxWidth: .infinity) }
            }
            if wide {
                HStack(spacing: 8) {
                    takesKey
                    flipKey
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func modeKeys(wide: Bool) -> some View {
        let layout = wide ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        return layout {
            ForEach(CameraRig.Mode.allCases, id: \.self) { mode in
                Button {
                    rig.setMode(mode)
                } label: {
                    Text(mode.title).font(Theme.mono(10, weight: .bold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.instrument(.key, active: rig.mode == mode, height: 36))
                .disabled(rig.isRecording && rig.mode != mode)
                .accessibilityAddTraits(rig.mode == mode ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }

    /// Done, with how many takes went in this visit.
    private var takesKey: some View {
        Button {
            onDone()
        } label: {
            VStack(spacing: 2) {
                Text("DONE").font(Theme.mono(10, weight: .bold))
                Text("\(model.takesThisVisit) TAKE\(model.takesThisVisit == 1 ? "" : "S")")
                    .font(Theme.mono(7, weight: .bold))
                    .opacity(0.7)
            }
            .frame(width: 64)
        }
        .buttonStyle(.instrument(.key, height: 48))
        .disabled(rig.isRecording)
        .accessibilityLabel("Done")
        .accessibilityValue("\(model.takesThisVisit) takes added")
    }

    @ViewBuilder
    private var flipKey: some View {
        let usable = rig.mode != .sound && rig.hasCamera && rig.cameraAccess == .granted
        Button {
            rig.flipCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 64)
        }
        .buttonStyle(.instrument(.key, height: 48))
        .disabled(!usable || rig.isRecording)
        .opacity(usable ? 1 : 0.3)
        .accessibilityLabel("Switch camera")
        .accessibilityValue(rig.position == .front ? "Front" : "Back")
    }

    private var canShoot: Bool {
        switch rig.mode {
        case .video: rig.cameraAccess == .granted && rig.hasCamera
        case .photo: rig.cameraAccess == .granted && rig.hasCamera
        case .sound: rig.micAccess == .granted
        }
    }
}

/// The shutter: a red record key for video and sound (a square while it runs), a white one for
/// photos, in a machined ring.
private struct ShutterKey: View {
    let mode: CameraRig.Mode
    let isRecording: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.ivory, Theme.aluminum, Color(hex: 0x8E9084)], startPoint: .top,
                            endPoint: .bottom)
                    )
                    .frame(width: 78, height: 78)
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 3)
                Circle().fill(Theme.obsidian).frame(width: 68, height: 68)
                RoundedRectangle(cornerRadius: isRecording ? 6 : 29, style: .continuous)
                    .fill(mode == .photo ? Theme.ivory : Theme.playhead)
                    .frame(width: isRecording ? 28 : 58, height: isRecording ? 28 : 58)
                    .shadow(color: (mode == .photo ? Theme.ivory : Theme.playhead).opacity(0.6), radius: 6)
            }
            .animation(.easeInOut(duration: 0.18), value: isRecording)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch mode {
        case .photo: "Take photo"
        case .video: isRecording ? "Stop recording" : "Record video"
        case .sound: isRecording ? "Stop recording" : "Record sound"
        }
    }
}

/// The camera's live picture.
private struct CameraPreview: UIViewRepresentable {
    let rig: CameraRig

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        rig.attach(view.previewLayer)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

/// Tucks a corner panel away: a tap, or a swipe down, folds it to a small key; a tap or a
/// swipe up on the key brings it back.
private struct Folding: ViewModifier {
    @Binding var shows: Bool

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { g in
                let down = g.translation.height > 16 && abs(g.translation.height) > abs(g.translation.width)
                let up = g.translation.height < -16 && abs(g.translation.height) > abs(g.translation.width)
                if (shows && down) || (!shows && up) { fold() }
            })
    }

    func fold() {
        withAnimation(.easeInOut(duration: 0.18)) { shows.toggle() }
        Haptics.tap()
    }
}

/// A folded corner panel's key: a small smoked capsule.
private struct FoldedKey: View {
    let title: String
    var lit = false

    var body: some View {
        HStack(spacing: 4) {
            if lit { Circle().fill(Theme.signal).frame(width: 5, height: 5) }
            Text(title).font(Theme.mono(9, weight: .bold)).foregroundStyle(Theme.label)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(Theme.aluminum.opacity(0.5), lineWidth: 1))
    }
}

/// The histogram in the picture's corner; tap or swipe it down to a small RGB key, and back.
private struct ScopeCorner: View {
    let rig: CameraRig
    @AppStorage("record.showsHistogram") private var shows = true

    var body: some View {
        Button {
            Folding(shows: $shows).fold()
        } label: {
            if shows {
                HistogramScope(histogram: rig.histogram).frame(width: 120, height: 56)
            } else {
                FoldedKey(title: "RGB")
            }
        }
        .buttonStyle(.plain)
        .modifier(Folding(shows: $shows))
        .accessibilityLabel(shows ? "Hide histogram" : "Show histogram")
    }
}

/// The camera's settings beside the histogram, on the same smoked panel: f-stop, shutter, ISO
/// and white balance (in the rings' yellow when set by hand), and under them the look, a menu
/// of the app's looks by kind, imported ones and importing a `.cube`. A tap on the settings, or
/// a swipe down, folds it to a small CAM key (lit while a look is on); the key brings it back.
private struct CameraReadout: View {
    let rig: CameraRig
    let onImport: () -> Void
    @AppStorage("record.showsCameraData") private var shows = true

    var body: some View {
        Group {
            if shows {
                panel
            } else {
                Button {
                    Folding(shows: $shows).fold()
                } label: {
                    FoldedKey(title: "CAM", lit: rig.look != nil)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show camera settings")
            }
        }
        .modifier(Folding(shows: $shows))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                GridRow {
                    value(aperture)
                    value(shutter, manual: !rig.isAutoExposure)
                }
                GridRow {
                    value(iso, manual: !rig.isAutoExposure)
                    value(kelvin, manual: !rig.isAutoWhiteBalance)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { Folding(shows: $shows).fold() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Folds the camera settings away.")
            lookMenu
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(height: 56)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.8)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.aluminum.opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func value(_ text: String, manual: Bool = false) -> some View {
        Text(text).font(Theme.mono(9, weight: .bold)).foregroundStyle(manual ? LensRing.engraving : Theme.label)
            .monospacedDigit()
    }

    private var data: CameraData { rig.cameraData }

    private var aperture: String { data.aperture > 0 ? String(format: "f/%.1f", data.aperture) : "f/–" }

    private var shutter: String {
        guard data.shutter > 0 else { return "1/–" }
        return data.shutter >= 1 ? String(format: "%.1fs", data.shutter) : "1/\(Int((1 / data.shutter).rounded()))"
    }

    private var iso: String { data.iso > 0 ? "ISO \(Int(data.iso.rounded()))" : "ISO –" }

    private var kelvin: String { data.kelvin > 0 ? "\(Int((data.kelvin / 100).rounded()) * 100)K" : "AWB" }

    private var lookMenu: some View {
        Menu {
            Button {
                rig.setLook(nil)
            } label: {
                Label("Clean", systemImage: rig.look == nil ? "checkmark" : "circle.slash")
            }
            ForEach(LookLibrary.builtInGroups, id: \.title) { group in
                Menu(group.title) {
                    ForEach(group.looks, id: \.id) { look in lookButton(look) }
                }
            }
            let imported = LookLibrary.imported()
            if !imported.isEmpty {
                Menu("Imported") {
                    ForEach(imported, id: \.id) { look in lookButton(look) }
                }
            }
            Button(action: onImport) {
                Label("Import .cube…", systemImage: "square.and.arrow.down")
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(rig.look == nil ? Theme.secondaryLabel.opacity(0.4) : Theme.signal)
                    .frame(width: 5, height: 5)
                Text(rig.look?.name ?? "CLEAN")
                    .font(Theme.mono(8, weight: .bold))
                    .foregroundStyle(rig.look == nil ? Theme.secondaryLabel : Theme.signal)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 6, weight: .bold))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            .frame(maxWidth: 96, alignment: .leading)
        }
        .disabled(!rig.canShowLooks || (rig.isRecording && rig.mode == .video))
        .accessibilityLabel("Look")
        .accessibilityValue(rig.look?.name ?? "Clean")
        .accessibilityHint("The look the picture is shot through. It stays on the take, and can be changed in the bin.")
    }

    private func lookButton(_ look: Look) -> some View {
        Button {
            rig.setLook(look)
        } label: {
            if rig.look?.id == look.id {
                Label(look.name, systemImage: "checkmark")
            } else {
                Text(look.name)
            }
        }
    }
}

/// The picture through the look, drawn by the rig from its frame copy.
private struct LookPreview: UIViewRepresentable {
    let rig: CameraRig

    final class DisplayView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    func makeUIView(context: Context) -> DisplayView {
        let view = DisplayView()
        view.backgroundColor = .clear
        view.displayLayer.videoGravity = .resizeAspectFill
        rig.attachLookRenderer(view.displayLayer.sampleBufferRenderer)
        return view
    }

    func updateUIView(_ view: DisplayView, context: Context) {}
}
