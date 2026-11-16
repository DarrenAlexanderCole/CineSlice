import EditCore
import SwiftUI
import UIKit

/// Release: 9:16 H.264, a sound policy (including silent for Instagram music),
/// the music sync note, progress + cancel, then Save to Photos / Share.
struct ExportSheet: View {
    var model: WorkspaceModel

    private enum Phase: Equatable {
        case ready
        case exporting(Double)
        case done(URL)
        case failed(String)
    }

    @State private var phase: Phase = .ready
    @State private var exportTask: Task<Void, Never>?
    @State private var savedToPhotos = false
    @State private var saveError: String?
    @State private var copiedSync = false

    var body: some View {
        let settings = model.project.exportSettings
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                details(settings)
                soundPicker(settings)
                if let music = model.project.referenceAudio {
                    syncNote(music)
                }
                content
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.obsidian)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isExporting)
        .onDisappear { exportTask?.cancel() }
    }

    @ViewBuilder
    private func details(_ settings: ExportSettings) -> some View {
        Text("Release").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.label)

        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            row("Duration", String(format: "%.2fs", model.project.duration.seconds))
            row("Frame", "\(settings.aspectLabel) · \(settings.width)×\(settings.height)")
            row("Format", "H.264 MP4 · \(settings.frameRate) fps")
            row("Clips", "\(model.project.clips.count)")
        }

    }

    // MARK: Sound

    /// Without music, "Clip sound" keeps the music flag on, so music added later is exported too.
    private var policies: [SoundPolicy] {
        model.project.referenceAudio == nil ? [.clipsAndMusic, .silent] : SoundPolicy.allCases
    }

    private func soundPicker(_ settings: ExportSettings) -> some View {
        let hasMusic = model.project.referenceAudio != nil
        let current = settings.soundPolicy
        let shown: SoundPolicy = hasMusic ? current : (current.includesClipAudio ? .clipsAndMusic : .silent)
        return VStack(alignment: .leading, spacing: 6) {
            Text("SOUND").font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
            ForEach(policies, id: \.self) { policy in
                Button {
                    model.setSoundPolicy(policy)
                    Haptics.detent()
                } label: {
                    HStack(spacing: 10) {
                        LED(isOn: shown == policy)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(policy, hasMusic: hasMusic))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Theme.label)
                            Text(detail(policy, hasMusic: hasMusic))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryLabel)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .frame(minHeight: Theme.minTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shown == policy ? .isSelected : [])
            }
        }
        .disabled(isExporting)
    }

    private func title(_ policy: SoundPolicy, hasMusic: Bool) -> String {
        switch policy {
        case .clipsAndMusic: return hasMusic ? "Clips + music" : "Clip sound"
        case .clipsOnly: return "Clip sound only"
        case .musicOnly: return "Music only"
        case .silent: return "Silent"
        }
    }

    private func detail(_ policy: SoundPolicy, hasMusic: Bool) -> String {
        switch policy {
        case .clipsAndMusic:
            return hasMusic ? "Exactly what you hear in the preview." : "The original sound from your clips."
        case .clipsOnly: return "Leaves the music out."
        case .musicOnly: return "Mutes the clips; keeps your music."
        case .silent: return "No sound. Add a licensed song inside Instagram afterwards."
        }
    }

    // MARK: Sync note

    /// Where the song sits against the video, for lining up the same song inside Instagram by hand.
    private func syncNote(_ music: AudioTrack) -> some View {
        let note = syncText(music)
        return VStack(alignment: .leading, spacing: 6) {
            Text("MUSIC SYNC").font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
            Text(note).font(Theme.mono(13)).foregroundStyle(Theme.label)
            Text(
                "Instagram doesn't let apps set its music start, so match it by hand there. It may not line up to the exact frame."
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryLabel)
            Button(copiedSync ? "Copied" : "Copy sync note") {
                UIPasteboard.general.string = "\(model.project.name): \(note)"
                copiedSync = true
                Haptics.success()
            }
            .buttonStyle(.instrument())
        }
    }

    private func syncText(_ music: AudioTrack) -> String {
        let song = music.originalFilename ?? "the song"
        if music.offset <= .zero {
            return "Start \(song) at \(clock(MediaTime.zero - music.offset))"
        }
        return "\(song) enters \(clock(music.offset)) into the video"
    }

    /// m:ss.cc, the way music apps show song positions.
    private func clock(_ t: MediaTime) -> String {
        let total = max(0, t.seconds)
        return String(format: "%d:%05.2f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }

    private var isExporting: Bool {
        if case .exporting = phase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .ready:
            Button("Render video") { start() }
                .buttonStyle(.instrument(.prominent))
                .frame(maxWidth: .infinity)

        case .exporting(let p):
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: p).tint(Theme.signal)
                HStack {
                    Text("\(Int(p * 100))%").font(Theme.mono(13)).foregroundStyle(Theme.label)
                    Spacer()
                    Button("Cancel") { exportTask?.cancel() }.buttonStyle(.instrument())
                }
            }

        case .done(let url):
            VStack(alignment: .leading, spacing: 10) {
                Label("Rendered", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.signal)
                HStack(spacing: 10) {
                    Button(savedToPhotos ? "Saved to Photos" : "Save to Photos") {
                        Task {
                            do {
                                try await ExportService.saveToPhotos(url)
                                savedToPhotos = true
                                Haptics.success()
                            } catch {
                                saveError = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.instrument(.key))
                    .disabled(savedToPhotos)
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.instrument())
                    Button("Again") {
                        phase = .ready
                        savedToPhotos = false
                    }
                    .buttonStyle(.instrument())
                }
                if let saveError {
                    Text(saveError).font(.system(size: 12)).foregroundStyle(Theme.aluminum)
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.aluminum)
                Button("Try again") { start() }.buttonStyle(.instrument(.key))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title.uppercased()).font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
            Text(value).font(Theme.mono(13)).foregroundStyle(Theme.label)
        }
    }

    private func start() {
        model.saveNow()
        let project = model.project
        let store = model.store
        phase = .exporting(0)
        exportTask = Task {
            do {
                let url = try await ExportService.export(project: project, store: store) { p in
                    if case .exporting = phase { phase = .exporting(p) }
                }
                phase = .done(url)
                Haptics.success()
            } catch is CancellationError {
                phase = .ready
            } catch ExportError.cancelled {
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
                Haptics.warning()
            }
        }
    }
}
