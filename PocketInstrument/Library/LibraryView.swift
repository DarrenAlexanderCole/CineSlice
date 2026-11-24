import EditCore
import SwiftUI

@MainActor
@Observable
final class LibraryModel {
    private(set) var projects: [Project] = []
    var errorMessage: String?
    let store: ProjectStore?

    init() {
        do {
            store = try ProjectStore.defaultStore()
        } catch {
            store = nil
            errorMessage = "Couldn't open project storage: \(error.localizedDescription)"
        }
    }

    func reload() {
        projects = store?.listProjects() ?? []
        measure()
    }

    // MARK: Storage

    /// Each project's footprint, measured off the main thread after every reload.
    private(set) var usage: [UUID: StorageUsage] = [:]
    /// Leftovers in the app's temporary and caches folders (interrupted imports and the like).
    private(set) var temporaryBytes: Int64 = 0
    @ObservationIgnored private var measureTask: Task<Void, Never>?

    var totalBytes: Int64 { usage.values.reduce(0) { $0 + $1.total } + temporaryBytes }
    var isOverStorageLimit: Bool { totalBytes >= ProjectStore.storageWarningBytes }

    nonisolated private static var temporaryFolders: [URL] {
        [FileManager.default.temporaryDirectory]
            + FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
    }

    func measure() {
        guard let store else { return }
        let ids = projects.map(\.id)
        measureTask?.cancel()
        measureTask = Task {
            let (usage, temporary) = await Task.detached(priority: .utility) {
                (
                    Dictionary(uniqueKeysWithValues: ids.map { ($0, store.usage(for: $0)) }),
                    Self.temporaryFolders.reduce(Int64(0)) { $0 + ProjectStore.size(of: $1) }
                )
            }.value
            guard !Task.isCancelled else { return }
            self.usage = usage
            self.temporaryBytes = temporary
        }
    }

    func clearRenders(_ project: Project) {
        do { try store?.clearExports(for: project.id) } catch { errorMessage = error.localizedDescription }
        measure()
    }

    func clearCache(_ project: Project) {
        do { try store?.clearCache(for: project.id) } catch { errorMessage = error.localizedDescription }
        measure()
    }

    /// Empties the app's temporary and caches folders. Only offered from the library, where no
    /// project is open and nothing is importing.
    func clearTemporaryFiles() {
        let fm = FileManager.default
        for folder in Self.temporaryFolders {
            for item in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: item)
            }
        }
        measure()
    }

    func create() -> Project? {
        guard let store else { return nil }
        do {
            let project = try store.create(name: "Untitled \(projects.count + 1)")
            reload()
            return project
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func rename(_ project: Project, to name: String) {
        guard let store else { return }
        var p = project
        try? RenameProjectCommand(name: name).apply(to: &p)
        p.modifiedAt = Date()
        do { try store.save(p) } catch { errorMessage = error.localizedDescription }
        reload()
    }

    func delete(_ project: Project) {
        do { try store?.delete(id: project.id) } catch { errorMessage = error.localizedDescription }
        reload()
    }

    func thumbnailURL(for project: Project) -> URL? {
        guard let store, let clip = project.clips.first, let source = project.source(for: clip),
            !store.isMissing(source, projectID: project.id)
        else { return nil }
        return store.mediaURL(for: source, projectID: project.id)
    }
}

/// Project library, built like an old table viewer: a sage-enamel machine at the top with a
/// lit screen showing the project at the gate, and the projects running out of it below as a
/// strip of film, newest first. Scroll to bring a title to the gate; tap one to open it.
struct LibraryView: View {
    @State private var library = LibraryModel()
    @State private var openProject: Project?
    @State private var renaming: Project?
    @State private var renameText = ""
    @State private var deleting: Project?
    /// The project at the gate (the top of the strip), shown in the viewer.
    @State private var atGate: UUID?
    @State private var showsStorage = false

    private let frameHeight: CGFloat = 66

    private var gateProject: Project? {
        library.projects.first { $0.id == atGate } ?? library.projects.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                viewer
                if library.isOverStorageLimit { storageBanner }
                strip
            }
            .background(
                ZStack {
                    Color(hex: 0x10120F)
                    Grain(opacity: 0.4)
                }
                .ignoresSafeArea()
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openProject) { project in
                if let store = library.store {
                    WorkspaceView(
                        model: WorkspaceModel(project: (try? store.load(id: project.id)) ?? project, store: store))
                }
            }
            .onAppear { library.reload() }
            .onChange(of: openProject) { _, value in
                if value == nil { library.reload() }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsStorage) {
            StorageSheet(library: library) { project in
                showsStorage = false
                deleting = project
            }
            .halfSheet()
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { if let p = renaming { library.rename(p, to: renameText) } }
        }
        .confirmationDialog(
            "Delete this project?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete project and its imported media", role: .destructive) {
                if let p = deleting { library.delete(p) }
            }
        } message: {
            Text("Your originals in Photos or Files are not affected.")
        }
        .alert(
            "Storage problem",
            isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    // MARK: The machine

    private var viewer: some View {
        VStack(spacing: 10) {
            hood
            namePlate
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .background(enamelBody)
        .padding(.horizontal, 10)
    }

    /// Sage enamel over cast metal: grain, a soft sheen across the top, and rivets.
    private var enamelBody: some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: 26, bottomTrailingRadius: 26, style: .continuous)
        return
            shape
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x95A57A), Theme.enamel, Color(hex: 0x5E6B44)], startPoint: .top,
                    endPoint: .bottom)
            )
            .overlay(Grain(opacity: 0.55).clipShape(shape))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.18), Color.black.opacity(0.5)], startPoint: .top,
                        endPoint: .bottom), lineWidth: 1.5)
            )
            .overlay(alignment: .bottom) {
                HStack {
                    Screw(angle: 40)
                    Spacer()
                    Screw(angle: -15)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .shadow(color: .black.opacity(0.8), radius: 12, y: 8)
            .ignoresSafeArea(edges: .top)
    }

    /// The black hood and its lit screen, with the gate's rail below.
    private var hood: some View {
        VStack(spacing: 0) {
            screen
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.black.shadow(.inner(color: .black, radius: 8, y: 4)))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.black.opacity(0.6)], startPoint: .top,
                                endPoint: .bottom), lineWidth: 1.5)
                )
            // The gate rail, screwed on.
            HStack {
                Screw(angle: 70)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.ivory, Theme.aluminum, Color(hex: 0x6D7067)], startPoint: .top,
                            endPoint: .bottom)
                    )
                    .overlay(Capsule().fill(Color.black.opacity(0.7)).frame(height: 1.5).padding(.horizontal, 30))
                    .frame(height: 6)
                Screw(angle: 10)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
        }
    }

    /// The lamp-lit picture of the project at the gate, warm and vignetted like a ground-glass
    /// screen; with nothing to show, a focus chart and the title.
    private var screen: some View {
        ZStack {
            Color(hex: 0xD9D3BD)
            if let project = gateProject, let url = library.thumbnailURL(for: project),
                let clip = project.clips.first
            {
                // Filled into the screen but held to its size, so the picture never widens the page.
                Color.clear
                    .overlay {
                        VideoFrameView(url: url, time: clip.sourceRange.start.cmTime, maxPixel: 480)
                            .scaledToFill()
                    }
                    .clipped()
                    .saturation(0.75)
                    .id(project.id)
                    .transition(.opacity)
            } else {
                FocusChart().opacity(0.55)
            }
            // The lamp: bright in the middle, falling off to the corners, a touch warm.
            RadialGradient(
                colors: [Color(hex: 0xFFF1C8).opacity(0.18), .clear, .black.opacity(0.55)], center: .center,
                startRadius: 10, endRadius: 190
            )
            .blendMode(.multiply)
            Grain(opacity: 0.35)
            if let project = gateProject {
                VStack {
                    Spacer()
                    Text(project.name)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: 0x23281F))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color(hex: 0xECE6D2).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                        .padding(.bottom, 10)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: atGate)
        .accessibilityElement()
        .accessibilityLabel(gateProject.map { "Viewer: \($0.name)" } ?? "Viewer")
    }

    /// Brushed aluminum, engraved, with the New knob at its right.
    private var namePlate: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("CS")
                    .font(.system(size: 11, weight: .heavy, design: .serif))
                    .foregroundStyle(Color(hex: 0x2A2416))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3).fill(
                            LinearGradient(
                                colors: [Color(hex: 0xD8C08A), Theme.brass, Color(hex: 0x8A7246)], startPoint: .top,
                                endPoint: .bottom))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("CineSlice")
                        .font(.system(size: 17, weight: .semibold, design: .serif).italic())
                    Text("\(library.projects.count) REELS · \(bytes(library.totalBytes))")
                        .font(Theme.mono(9, weight: .semibold))
                }
                .foregroundStyle(Color(hex: 0x2B2F27))
                .shadow(color: .white.opacity(0.5), radius: 0, y: 1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Theme.ivory, Theme.aluminum, Color(hex: 0xA2A498)], startPoint: .top,
                            endPoint: .bottom)
                    )
                    .overlay(
                        BrushedMetal(strength: 1.2).clipShape(RoundedRectangle(cornerRadius: 6)).blendMode(.multiply)
                    )
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
            )
            if let url = HelpManual.url {
                ShareLink(item: url) {
                    Image(systemName: "book")
                }
                .buttonStyle(.round(30))
                .accessibilityLabel("Manual")
                .accessibilityHint("Shares the CineSlice manual as a PDF, to save, print or send.")
            }
            Button {
                showsStorage = true
            } label: {
                Image(systemName: "internaldrive")
            }
            .buttonStyle(.round(30, lit: library.isOverStorageLimit))
            .disabled(library.store == nil)
            .accessibilityLabel("Storage")
            .accessibilityValue(bytes(library.totalBytes))
            .accessibilityHint("Shows the space each project takes, and clears renders and caches.")
            Button {
                if let p = library.create() { openProject = p }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.round(46, prominent: true))
            .disabled(library.store == nil)
            .accessibilityLabel("New")
            .accessibilityHint("Starts a new project")
        }
    }

    /// Past the storage limit: a lit strip under the machine that opens Storage.
    private var storageBanner: some View {
        Button {
            showsStorage = true
        } label: {
            HStack(spacing: 8) {
                LED(isOn: true)
                Text("USING \(bytes(library.totalBytes)) · FREE UP SPACE")
                    .font(Theme.mono(11, weight: .bold))
                    .foregroundStyle(Theme.signal)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(Theme.signal)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: Theme.minTouch)
            .recessed(padding: 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    // MARK: The strip

    private var strip: some View {
        ZStack(alignment: .top) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if library.projects.isEmpty {
                        Text("No reels yet. Press + to start one, import a few videos, and cut them into a 9:16 piece.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .padding(30)
                    }
                    ForEach(Array(library.projects.enumerated()), id: \.element.id) { index, project in
                        frame(project, number: index + 1)
                            .id(project.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $atGate, anchor: .top)
            .scrollTargetBehavior(.viewAligned)
            .safeAreaPadding(.top, 14)
            .safeAreaPadding(.bottom, 240)
            .onChange(of: atGate) { _, _ in Haptics.detent() }
            gate
        }
        .padding(.top, 6)
    }

    /// The gate's brackets, marking where a frame lines up with the viewer.
    private var gate: some View {
        HStack {
            Image(systemName: "arrowtriangle.right.fill")
            Spacer()
            Image(systemName: "arrowtriangle.left.fill")
        }
        .font(.system(size: 8))
        .foregroundStyle(Theme.signal)
        .shadow(color: Theme.signal.opacity(0.8), radius: 3)
        .padding(.horizontal, 3)
        .frame(height: frameHeight)
        .padding(.top, 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// One project as a frame of film: sprocket holes down both edges of an amber base,
    /// the title lit when it's at the gate.
    private func frame(_ project: Project, number: Int) -> some View {
        let isAtGate = project.id == (atGate ?? library.projects.first?.id)
        return Button {
            openProject = project
        } label: {
            HStack(spacing: 0) {
                sprockets
                HStack(spacing: 12) {
                    Text(String(format: "%02d", number))
                        .font(Theme.mono(11, weight: .bold))
                        .foregroundStyle(Theme.brass.opacity(0.9))
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isAtGate ? Theme.signal : Theme.ivory)
                            .shadow(color: isAtGate ? Theme.signal.opacity(0.5) : .clear, radius: 6)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            Text(project.modifiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            Text("·")
                            Text(MediaTime(seconds: project.duration.seconds).timecode())
                            Text("·")
                            Text("\(project.clips.count) \(project.clips.count == 1 ? "clip" : "clips")")
                        }
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.aluminum.opacity(0.75))
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.aluminum.opacity(isAtGate ? 0.9 : 0.35))
                }
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .background(
                    // The frame itself: dark amber base, lit from behind at the gate.
                    LinearGradient(
                        colors: isAtGate
                            ? [Color(hex: 0x3A3220), Color(hex: 0x2A2416)]
                            : [Color(hex: 0x231E14), Color(hex: 0x1A1610)],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.8)).frame(height: 2) }
                sprockets
            }
            .frame(height: frameHeight)
            .background(Color(hex: 0x1A1610))
            .overlay(Grain(opacity: 0.3))
            .padding(.horizontal, 22)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = project.name
                renaming = project
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = project
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityLabel("\(project.name), \(project.clips.count) clips")
        .accessibilityAction(named: "Rename") {
            renameText = project.name
            renaming = project
        }
        .accessibilityAction(named: "Delete") { deleting = project }
    }

    /// A column of sprocket holes along one edge of a frame.
    private var sprockets: some View {
        VStack(spacing: 7) {
            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(hex: 0x0B0C0A))
                    .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color.white.opacity(0.06)))
                    .frame(width: 8, height: 9)
            }
        }
        .frame(width: 18, height: frameHeight)
        .background(Color(hex: 0x1A1610))
    }
}

/// A focus test chart for an empty viewer: spoked stars like the cards projectionists lined up on.
private struct FocusChart: View {
    var body: some View {
        Canvas { context, size in
            let centres = [
                CGPoint(x: size.width * 0.5, y: size.height * 0.5),
                CGPoint(x: size.width * 0.18, y: size.height * 0.25),
                CGPoint(x: size.width * 0.82, y: size.height * 0.25),
                CGPoint(x: size.width * 0.18, y: size.height * 0.78),
                CGPoint(x: size.width * 0.82, y: size.height * 0.78),
            ]
            for (n, c) in centres.enumerated() {
                let r = n == 0 ? size.height * 0.36 : size.height * 0.2
                let spokes = 36
                for k in 0..<spokes where k % 2 == 0 {
                    let a0 = Double(k) / Double(spokes) * 2 * .pi
                    let a1 = Double(k + 1) / Double(spokes) * 2 * .pi
                    var p = Path()
                    p.move(to: c)
                    p.addArc(center: c, radius: r, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
                    p.closeSubpath()
                    context.fill(p, with: .color(Color(hex: 0x2A2A26)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// Where the space goes: the total against the 10 GB mark, leftover temporary files, and each
/// project, biggest first, split into its footage, renders and cache. Renders, cache and
/// temporary files can be cleared on the spot; footage goes only with its project.
private struct StorageSheet: View {
    var library: LibraryModel
    var onDelete: (Project) -> Void

    private var projects: [Project] {
        library.projects.sorted { (library.usage[$0.id]?.total ?? 0) > (library.usage[$1.id]?.total ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                TitlePlate(
                    title: "Storage", subtitle: "\(library.projects.count) reels on this \(UIDevice.current.model)")
                PanelSection(title: "In use") { gauge }
                PanelSection(title: "Temporary files") { temporary }
                EngravedLabel("Projects · biggest first").padding(.leading, 4)
                ForEach(projects) { project in
                    row(project, library.usage[project.id] ?? StorageUsage())
                }
                Text(
                    "Footage is each project's own copy of its clips and music, so your originals in Photos or Files are never touched. It goes only when you delete the project."
                )
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryLabel)
            }
            .padding(.horizontal, 16)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .presentationBackground { Chassis(cornerRadius: 0) }
        .presentationCornerRadius(26)
        .preferredColorScheme(.dark)
        .onAppear { library.measure() }
    }

    /// The total as a lit bar against the 10 GB mark.
    private var gauge: some View {
        let limit = Double(ProjectStore.storageWarningBytes)
        let share = min(Double(library.totalBytes) / limit, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(bytes(library.totalBytes))
                    .font(Theme.mono(26, weight: .bold))
                    .foregroundStyle(library.isOverStorageLimit ? Theme.signal : Theme.label)
                Text("of \(bytes(ProjectStore.storageWarningBytes))")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            SegmentMeter(value: share)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Using \(bytes(library.totalBytes)) of \(bytes(ProjectStore.storageWarningBytes))")
    }

    private var temporary: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Left over from imports and previews. \(bytes(library.temporaryBytes)).")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Spacer(minLength: 8)
            Button("Clear") {
                library.clearTemporaryFiles()
                Haptics.success()
            }
            .buttonStyle(.instrument(height: 32))
            .disabled(library.temporaryBytes == 0)
            .accessibilityLabel("Clear temporary files")
        }
    }

    private func row(_ project: Project, _ usage: StorageUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(project.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(bytes(usage.total)).font(Theme.mono(13, weight: .bold)).foregroundStyle(Theme.label)
            }
            Text(
                "Footage \(bytes(usage.media)) · Renders \(bytes(usage.exports)) · Cache \(bytes(usage.cache))"
            )
            .font(Theme.mono(10))
            .foregroundStyle(Theme.secondaryLabel)
            HStack(spacing: 8) {
                Button("Clear renders") {
                    library.clearRenders(project)
                    Haptics.success()
                }
                .buttonStyle(.instrument(height: 32))
                .disabled(usage.exports == 0)
                .accessibilityLabel("Clear renders of \(project.name)")
                Button("Clear cache") {
                    library.clearCache(project)
                    Haptics.success()
                }
                .buttonStyle(.instrument(height: 32))
                .disabled(usage.cache == 0)
                .accessibilityLabel("Clear cache of \(project.name)")
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    onDelete(project)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.instrument(height: 32))
                .accessibilityLabel("Delete \(project.name)")
            }
        }
        .padding(12)
        .recessed(padding: 0)
    }
}
