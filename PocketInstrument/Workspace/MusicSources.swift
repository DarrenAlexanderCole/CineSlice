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

    @State private var showsMyMusic = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TitlePlate(title: "Music", subtitle: "A reference to cut against")
                PanelSection(title: "Choose a source") {
                    myMusic
                    choice(
                        2, "Quick Click", "A click guide at your tempo. No song needed.", icon: "metronome",
                        isOn: false
                    ) {}
                    .disabled(true)
                    choice(
                        3, "Billboards", "Name the song you'll add in Instagram and tap its rhythm.",
                        icon: "music.quarternote.3", isOn: false
                    ) {}
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
        .presentationBackground { Chassis(cornerRadius: 0) }
        .presentationCornerRadius(26)
        .preferredColorScheme(.dark)
    }

    private var hasSong: Bool { model.project.referenceAudio != nil }

    /// My Music opens to its sources in place: Files, a video's sound, or the demo click.
    @ViewBuilder
    private var myMusic: some View {
        choice(
            1, "My Music", "A song on this iPhone: from Files, or the sound of a video.", icon: "music.note.list",
            isOn: showsMyMusic
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
