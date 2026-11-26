import EditCore
import SwiftUI

/// LIGHTBOX's monitor screen: the live picture of the sequence cut to the project's own frame
/// shape, so there's no black around it, set into the chassis behind a machined metal cap. It is
/// the same player the table edits, so the roller, scrubbing and play all show here.
struct MonitorScreen: View {
    var model: WorkspaceModel
    var onFullScreen: () -> Void

    /// The metal cap round the picture.
    static let bezel: CGFloat = 5

    /// Width over height of the project's frame.
    static func aspect(_ model: WorkspaceModel) -> CGFloat {
        let settings = model.project.exportSettings
        return CGFloat(settings.width) / CGFloat(max(settings.height, 1))
    }

    var body: some View {
        ZStack {
            Color.black
            if model.project.clips.isEmpty {
                Image(systemName: "film")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.secondaryLabel.opacity(0.6))
                    .accessibilityLabel("No picture yet")
            } else {
                PlayerView(player: model.engine.player)
            }
            if let status = model.importStatus {
                VStack {
                    Spacer()
                    HStack(spacing: 5) {
                        ProgressView().tint(Theme.signal).controlSize(.mini)
                        Text(status).font(Theme.mono(8, weight: .semibold)).foregroundStyle(Theme.label)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.7)))
                    .padding(5)
                }
            }
        }
        .aspectRatio(Self.aspect(model), contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if !model.project.clips.isEmpty {
                Button(action: onFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.label.opacity(0.9))
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .padding(4)
                        .frame(minWidth: Theme.minTouch, minHeight: Theme.minTouch, alignment: .bottomTrailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview")
                .accessibilityHint("Plays the picture full screen; closing comes back to the same frame.")
            }
        }
        .metalBezel(cornerRadius: 9, width: Self.bezel)
    }
}

/// The time counter: a backlit window under the same metal cap, the playhead's timecode lit warm
/// behind smoked glass and the project's length beside it, dimmer.
struct BacklitCounter: View {
    var time: MediaTime
    var duration: MediaTime
    var frameRate: Double

    private static let glow = Color(hex: 0xFFB54A)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TimecodeText(time: time, frameRate: frameRate, size: 12, color: Self.glow)
                .shadow(color: Self.glow.opacity(0.75), radius: 3)
            TimecodeText(time: duration, frameRate: frameRate, size: 7, color: Self.glow.opacity(0.45))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                // Smoked glass, lit from behind in the middle, with a reflection along its top.
                Color(hex: 0x16120C)
                RadialGradient(
                    colors: [Self.glow.opacity(0.16), .clear], center: .center, startRadius: 2, endRadius: 70)
                LinearGradient(
                    stops: [.init(color: .white.opacity(0.08), location: 0), .init(color: .clear, location: 0.45)],
                    startPoint: .top, endPoint: .bottom)
            }
        )
        .metalBezel(cornerRadius: 6, width: 3)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Set into the chassis under a machined aluminium cap: a bevelled ring lit from above, the
    /// content flush inside it behind a fine chamfer, with no dark gap between.
    func metalBezel(cornerRadius: CGFloat, width: CGFloat) -> some View {
        let outer = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: max(1, cornerRadius - width), style: .continuous)
        return self.clipShape(inner)
            // The chamfer: shade where the cap's edge overhangs the top, a lit lip along the bottom.
            .overlay(
                inner.strokeBorder(
                    LinearGradient(
                        colors: [Color.black.opacity(0.55), Color.black.opacity(0.15), Color.white.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 1
                )
                .allowsHitTesting(false)
            )
            .padding(width)
            .background(
                ZStack {
                    outer.fill(
                        LinearGradient(
                            colors: [Color(hex: 0xE6E7DC), Theme.aluminum, Color(hex: 0x8A8D81), Color(hex: 0x5F6258)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                    BrushedMetal(strength: 1).clipShape(outer).blendMode(.multiply)
                    outer.strokeBorder(Color.white.opacity(0.45), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1.5)
                .allowsHitTesting(false)
            )
    }
}

/// The keys that bring footage, music and sounds straight onto the table, as symbols beside Tools.
/// Clips go in at the cut nearest the playhead; music opens the same sheet as upright Mix; a
/// sound lands at the playhead on the first sound lane with room.
struct LightboxBringInKeys: View {
    var model: WorkspaceModel
    /// A row of keys, or a column where the console is narrow.
    var axis: Axis = .horizontal
    /// Opens Photos (true) or Files (false) for clips.
    var onAddClips: (_ photos: Bool) -> Void
    /// Opens Files (false) or a video's sound (true) for the music, once the music sheet has gone.
    var onAddMusic: (_ fromVideo: Bool) -> Void
    /// Opens Files (false) or a video's sound (true) for a sound.
    var onAddSound: (_ fromVideo: Bool) -> Void

    @State private var showsMusic = false
    @State private var pendingPick: MusicSourceSheet.Pick?

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(spacing: 8))
        layout {
            Menu {
                Button {
                    onAddClips(true)
                } label: {
                    Label("From Photos", systemImage: "photo.on.rectangle")
                }
                Button {
                    onAddClips(false)
                } label: {
                    Label("From Files", systemImage: "folder")
                }
                Button {
                    Task { await model.addDemoClips(at: model.cutIndexNearPlayhead) }
                } label: {
                    Label("Demo clips", systemImage: "film.stack")
                }
            } label: {
                symbol("film")
            }
            .menuStyle(.button)
            .buttonStyle(.instrument(.key, height: 34))
            .accessibilityLabel("Add clips")
            .accessibilityHint("New clips go in at the cut nearest the playhead.")
            Button {
                model.engine.pause()
                showsMusic = true
            } label: {
                symbol("music.note")
            }
            .buttonStyle(.instrument(.key, height: 34))
            .accessibilityLabel("Music")
            .accessibilityHint("Chooses the music under the sequence.")
            Menu {
                Button {
                    onAddSound(false)
                } label: {
                    Label("From Files", systemImage: "folder")
                }
                Button {
                    onAddSound(true)
                } label: {
                    Label("Sound of a video", systemImage: "film")
                }
                Button {
                    Task { await model.addDemoSound() }
                } label: {
                    Label("Demo sound", systemImage: "waveform")
                }
            } label: {
                symbol("waveform")
            }
            .menuStyle(.button)
            .buttonStyle(.instrument(.key, height: 34))
            .accessibilityLabel("Add sound")
            .accessibilityHint("A sound goes in at the playhead, on the first sound lane with room.")
        }
        .sheet(isPresented: $showsMusic, onDismiss: openPendingPick) {
            MusicSourceSheet(model: model) { pendingPick = $0 }
                .presentationDetents([.large])
        }
    }

    /// The symbol with a small plus at its shoulder: "bring in".
    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .bold))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 7, weight: .heavy))
                    .offset(x: 6, y: -4)
            }
            .padding(.trailing, 3)
    }

    /// Opens the system picker the music sheet asked for, now that it has closed.
    private func openPendingPick() {
        switch pendingPick {
        case .files: onAddMusic(false)
        case .video: onAddMusic(true)
        case nil: break
        }
        pendingPick = nil
    }
}
