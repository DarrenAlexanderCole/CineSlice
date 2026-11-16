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

    func reload() { projects = store?.listProjects() ?? [] }

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

/// Project library: visual cards, newest first. Create, open, rename, delete.
struct LibraryView: View {
    @State private var library = LibraryModel()
    @State private var openProject: Project?
    @State private var renaming: Project?
    @State private var renameText = ""
    @State private var deleting: Project?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if library.projects.isEmpty {
                        Text("No projects yet. Start one, import a few videos, and arrange them into a 9:16 piece.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryLabel)
                            .padding(.top, 20)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(library.projects) { project in
                            card(project)
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.obsidian.ignoresSafeArea())
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

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("PROJECTS").font(Theme.caption).foregroundStyle(Theme.secondaryLabel)
                Text("Pocket Instrument").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.label)
            }
            Spacer()
            Button {
                if let p = library.create() { openProject = p }
            } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(.instrument(.prominent))
            .disabled(library.store == nil)
        }
    }

    private func card(_ project: Project) -> some View {
        Button {
            openProject = project
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let url = library.thumbnailURL(for: project), let clip = project.clips.first {
                        VideoFrameView(url: url, time: clip.sourceRange.start.cmTime, maxPixel: 300)
                    } else {
                        Theme.instrument
                        Image(systemName: "film").foregroundStyle(Theme.aluminum)
                    }
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))

                Text(project.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.label).lineLimit(1)
                HStack {
                    Text(project.modifiedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Spacer()
                    Text(MediaTime(seconds: project.duration.seconds).timecode())
                }
                .font(Theme.caption)
                .foregroundStyle(Theme.secondaryLabel)
            }
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
}
