import AVFoundation
import SwiftUI

@main
struct PocketInstrumentApp: App {
    /// UI tests launch with `-skipIntro` so their first taps reach the library.
    @State private var showsIntro = !ProcessInfo.processInfo.arguments.contains("-skipIntro")

    init() {
        // The default session (.soloAmbient) obeys the ring/silent switch, so preview was mute on a
        // silenced iPhone while exported files played fine in Photos. An editor should always be heard.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                LibraryView()
                if showsIntro {
                    IntroView { showsIntro = false }
                }
            }
            .tint(Theme.signal)
        }
    }
}

/// The opening: two brushed-metal shutters closed over the screen with the CineSlice plate across
/// them. A Signal blade slices across the plate, then the shutters part, each taking its half of the
/// plate, and the library is behind them. A tap skips it; with Reduce Motion it simply fades.
private struct IntroView: View {
    var onDone: () -> Void

    private enum Stage: Int { case closed, titled, sliced, open }
    @State private var stage = Stage.closed
    @State private var task: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let apart = stage == .open ? half + 20 : 0
            ZStack {
                shutter(leading: true, half: half)
                    .offset(x: -apart)
                shutter(leading: false, half: half)
                    .offset(x: apart)
            }
            .opacity(reduceMotion && stage == .open ? 0 : 1)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement()
        .accessibilityLabel("CineSlice")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("intro")
        .onAppear(perform: run)
        .onDisappear { task?.cancel() }
    }

    /// One shutter: brushed metal with a seam at the middle, carrying its half of the title plate.
    private func shutter(leading: Bool, half: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x6B735B), Color(hex: 0x4B5539), Color(hex: 0x2A3020)], startPoint: .top,
                endPoint: .bottom
            )
            .overlay(BrushedMetal(strength: 1.4))
            .overlay(Grain(opacity: 0.6))
            // The meeting edge: lit on one side, shadowed on the other.
            HStack(spacing: 0) {
                if !leading { Rectangle().fill(Color.black.opacity(0.6)).frame(width: 2) }
                Spacer()
                if leading { Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1.5) }
            }
            VStack {
                HStack {
                    if !leading { Spacer() }
                    Screw(angle: leading ? 30 : -60)
                    if leading { Spacer() }
                }
                Spacer()
                HStack {
                    if !leading { Spacer() }
                    Screw(angle: leading ? -20 : 70)
                    if leading { Spacer() }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 70)
            plate
                .frame(width: half * 2)
                .offset(x: leading ? half / 2 : -half / 2)
        }
        .frame(width: half)
        .clipped()
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
        .shadow(color: .black.opacity(stage == .open ? 0.8 : 0), radius: 16)
    }

    /// The name plate across both shutters, with the slice through it.
    private var plate: some View {
        VStack(spacing: 6) {
            Text("CineSlice")
                .font(.system(size: 44, weight: .semibold, design: .serif).italic())
                .foregroundStyle(Color(hex: 0x2B2F27))
                .shadow(color: .white.opacity(0.55), radius: 0, y: 1.5)
            Text("9:16 FILM EDITING TABLE")
                .font(Theme.mono(10, weight: .bold))
                .tracking(2)
                .foregroundStyle(Color(hex: 0x3A3F34))
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.ivory, Theme.aluminum, Color(hex: 0xA2A498)], startPoint: .top,
                        endPoint: .bottom)
                )
                .overlay(BrushedMetal(strength: 1.2).clipShape(RoundedRectangle(cornerRadius: 10)).blendMode(.multiply))
                .shadow(color: .black.opacity(0.6), radius: 4, y: 3)
        )
        .overlay {
            // The blade's cut: a Signal line drawn down through the plate at the seam.
            Rectangle()
                .fill(Theme.signal)
                .frame(width: 2.5)
                .shadow(color: Theme.signal, radius: 6)
                .scaleEffect(y: stage.rawValue >= Stage.sliced.rawValue ? 1.4 : 0, anchor: .top)
                .opacity(stage == .open ? 0 : 1)
        }
        .scaleEffect(stage == .closed ? 0.92 : 1)
        .opacity(stage == .closed ? 0 : 1)
    }

    private func run() {
        task = Task {
            withAnimation(.easeOut(duration: 0.45)) { stage = .titled }
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            if !reduceMotion {
                withAnimation(.easeIn(duration: 0.22)) { stage = .sliced }
                Haptics.press()
                try? await Task.sleep(for: .seconds(0.4))
                guard !Task.isCancelled else { return }
            }
            // UI tests hold the sliced plate up for a screenshot, then tap through it.
            guard !ProcessInfo.processInfo.arguments.contains("-holdIntro") else { return }
            finish()
        }
    }

    private func finish() {
        task?.cancel()
        guard stage != .open else { return }
        Haptics.detent()
        withAnimation(reduceMotion ? .easeOut(duration: 0.3) : .spring(response: 0.6, dampingFraction: 0.9)) {
            stage = .open
        }
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            onDone()
        }
    }
}
