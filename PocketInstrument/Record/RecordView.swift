import AVFoundation
import EditCore
import SwiftUI

/// The Record page: the camera's live picture behind a metal cap, a backlit counter, the mode
/// keys (video, photo, sound) and the shutter. Every take, sound too, goes into the bin's TAKES
/// folder as soon as it stops, to put on the timeline from there. The page stays open for more
/// takes until Done. Upright, the keys sit under the picture; held sideways,
/// in a column beside it. Two lens rings turn the zoom and focus: across the screen under the
/// picture upright, stood up on its left held sideways, where the left hand works them like a
/// lens. A live RGB histogram sits in the picture's corner.
struct RecordView: View {
    var model: WorkspaceModel
    var onDone: () -> Void

    @State private var rig: CameraRig
    /// Where the picture was last tapped to focus, shown for a moment.
    @State private var focusMark: CGPoint?

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
                screen
                    .metalBezel(cornerRadius: 14, width: 5)
                    .overlay(alignment: .top) { counter.padding(.top, 14) }
                if !wide, showsRings { rings(vertical: false).frame(height: 78) }
                controls(wide: wide)
                    .frame(width: wide ? 132 : nil, height: wide ? nil : 190)
            }
            .padding(.horizontal, wide ? 12 : 10)
            .padding(.vertical, 8)
            .animation(.easeInOut(duration: 0.2), value: showsRings)
        }
        .background(Theme.obsidian.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task {
            model.beginRecording()
            rig.onTake = { take in Task { await model.addTake(take) } }
            rig.onError = { model.alertMessage = $0 }
            await rig.start()
        }
        .onDisappear { rig.stop() }
    }

    // MARK: Screen

    @ViewBuilder
    private var screen: some View {
        ZStack {
            Color.black
            if rig.mode == .sound {
                SoundMeter(level: rig.level, isRecording: rig.isRecording, access: rig.micAccess)
            } else if rig.cameraAccess == .denied {
                notice(
                    "Camera access is off", "Turn it on in Settings to record video and photos here.", settings: true)
            } else if !rig.hasCamera {
                notice("No camera", "This device has no camera to record with. Sound still works.", settings: false)
            } else {
                CameraPreview(rig: rig)
                    .onTapGesture { point in
                        rig.focus(atLayerPoint: point)
                        focusMark = point
                        Haptics.tap()
                    }
                    .overlay(alignment: .topLeading) { focusSquare }
                if rig.flash { Color.white.opacity(0.7).allowsHitTesting(false) }
                ScopeCorner(rig: rig)
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

    private var showsRings: Bool { rig.mode != .sound && rig.cameraAccess == .granted && rig.hasCamera }

    private func rings(vertical: Bool) -> some View {
        let layout = vertical ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
        return layout {
            ringRow("ZOOM", String(format: "%.1f×", rig.zoom), vertical: vertical, ring: zoomRing(vertical: vertical))
            ringRow("FOCUS", focusReadout, vertical: vertical, ring: focusRing(vertical: vertical)) {
                rig.toggleManualFocus()
            }
        }
    }

    /// A ring with its name and reading beside it. With `onToggle` the name plate is a key
    /// (focus: AF or manual).
    private func ringRow(
        _ title: String, _ readout: String, vertical: Bool, ring: LensRing, onToggle: (() -> Void)? = nil
    ) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
        let plate = VStack(spacing: 1) {
            Text(title).font(Theme.mono(7, weight: .bold)).foregroundStyle(Theme.secondaryLabel)
            Text(readout).font(Theme.mono(10, weight: .bold)).foregroundStyle(LensRing.engraving)
                .monospacedDigit()
        }
        return layout {
            if let onToggle {
                Button(action: onToggle) { plate.frame(width: 44) }
                    .buttonStyle(.instrument(.dark, active: !rig.isAutoFocus, height: 34))
                    .frame(width: 48)
                    .disabled(!rig.canFocus)
                    .accessibilityLabel("Manual focus")
                    .accessibilityValue(rig.isAutoFocus ? "Off" : "On")
                    .accessibilityHint("Turn the ring to focus by hand. Off, the camera focuses itself.")
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

/// Sound mode's screen: a backlit level meter of the microphone.
private struct SoundMeter: View {
    let level: Float
    let isRecording: Bool
    let access: CameraRig.Access

    private static let segments = 24

    var body: some View {
        VStack(spacing: 14) {
            if access == .denied {
                Text("MICROPHONE ACCESS IS OFF").font(Theme.mono(11, weight: .bold)).foregroundStyle(Theme.label)
                Text("Turn it on in Settings to record sound.")
                    .font(.footnote).foregroundStyle(Theme.secondaryLabel)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(isRecording ? Theme.playhead : Theme.secondaryLabel)
                HStack(spacing: 3) {
                    ForEach(0..<Self.segments, id: \.self) { i in
                        let lit = Float(i) / Float(Self.segments) < level
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color(i).opacity(lit ? 1 : 0.15))
                            .frame(width: 6, height: 26)
                            .shadow(color: lit ? color(i).opacity(0.7) : .clear, radius: 3)
                    }
                }
                Text(isRecording ? "RECORDING SOUND" : "SOUND ONLY · GOES IN THE BIN")
                    .font(Theme.mono(8, weight: .bold))
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    private func color(_ i: Int) -> Color {
        let f = Double(i) / Double(Self.segments)
        return f > 0.85 ? Theme.playhead : f > 0.65 ? Color(hex: 0xFFB54A) : Theme.signal
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

/// The histogram in the picture's corner; tap it away to a small RGB key, and back.
private struct ScopeCorner: View {
    let rig: CameraRig
    @AppStorage("record.showsHistogram") private var shows = true

    var body: some View {
        Button {
            shows.toggle()
            Haptics.tap()
        } label: {
            if shows {
                HistogramScope(histogram: rig.histogram).frame(width: 120, height: 56)
            } else {
                Text("RGB")
                    .font(Theme.mono(9, weight: .bold))
                    .foregroundStyle(Theme.label)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .overlay(Capsule().strokeBorder(Theme.aluminum.opacity(0.5), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shows ? "Hide histogram" : "Show histogram")
    }
}
