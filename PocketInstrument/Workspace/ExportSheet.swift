import EditCore
import SwiftUI

/// Release (minimal for Phase 1): 9:16 H.264, optional silent export,
/// progress + cancel, then Save to Photos / Share.
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

    var body: some View {
        let settings = model.project.exportSettings
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.label)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                row("Duration", String(format: "%.2fs", model.project.duration.seconds))
                row("Frame", "\(settings.aspectLabel) · \(settings.width)×\(settings.height)")
                row("Format", "H.264 MP4 · \(settings.frameRate) fps")
                row("Clips", "\(model.project.clips.count)")
            }

            Toggle(
                isOn: Binding(
                    get: { settings.includeClipAudio },
                    set: { model.setIncludeClipAudio($0) })
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include clip audio").foregroundStyle(Theme.label)
                    Text(
                        settings.includeClipAudio
                            ? "Original sound from your clips is kept."
                            : "Silent export. Add the licensed song in Instagram afterwards. Instagram's music offset can't be set precisely from here."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                }
            }
            .tint(Theme.olive)
            .disabled(isExporting)

            Spacer(minLength: 0)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.obsidian)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isExporting)
        .onDisappear { exportTask?.cancel() }
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
