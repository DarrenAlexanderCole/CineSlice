import Foundation

/// File-based project persistence:
///
///     <root>/<project-id>/project.json
///     <root>/<project-id>/Media/<uuid>.<ext>     imported copies (never modified)
///     <root>/<project-id>/Exports/...            rendered files
///     <root>/<project-id>/Cache/...              derived data (waveforms); safe to delete
///
/// JSON is written atomically, so an interrupted save never corrupts the last good copy.
public final class ProjectStore: @unchecked Sendable {
    public let rootURL: URL
    private let fm = FileManager.default

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// Default location: Application Support/Projects (not user-visible, backed up).
    public static func defaultStore() throws -> ProjectStore {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return try ProjectStore(rootURL: support.appendingPathComponent("Projects", isDirectory: true))
    }

    public func directory(for projectID: UUID) -> URL {
        rootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    public func mediaDirectory(for projectID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("Media", isDirectory: true)
    }

    public func exportsDirectory(for projectID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("Exports", isDirectory: true)
    }

    public func mediaURL(for source: SourceAsset, projectID: UUID) -> URL {
        mediaDirectory(for: projectID).appendingPathComponent(source.fileName)
    }

    public func isMissing(_ source: SourceAsset, projectID: UUID) -> Bool {
        !fm.fileExists(atPath: mediaURL(for: source, projectID: projectID).path)
    }

    /// The music file, or nil when it's missing.
    public func audioURL(for track: AudioTrack, projectID: UUID) -> URL? {
        let url = mediaDirectory(for: projectID).appendingPathComponent(track.fileName)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    public func waveformCacheURL(for track: AudioTrack, projectID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("\(track.fileName).waveform")
    }

    private func fileURL(for projectID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("project.json")
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Default (reference-date seconds) round-trips exactly; ISO-8601 would drop sub-seconds.
        return e
    }()

    static let decoder: JSONDecoder = {
        JSONDecoder()
    }()

    @discardableResult
    public func create(name: String) throws -> Project {
        let project = Project(name: name)
        try fm.createDirectory(at: mediaDirectory(for: project.id), withIntermediateDirectories: true)
        try save(project)
        return project
    }

    public func save(_ project: Project) throws {
        try fm.createDirectory(at: directory(for: project.id), withIntermediateDirectories: true)
        let data = try ProjectStore.encoder.encode(project)
        try data.write(to: fileURL(for: project.id), options: .atomic)
    }

    public func load(id: UUID) throws -> Project {
        let data = try Data(contentsOf: fileURL(for: id))
        return try ProjectStore.decoder.decode(Project.self, from: data)
    }

    /// All readable projects, most recently modified first. Unreadable folders are skipped.
    public func listProjects() -> [Project] {
        let dirs = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> Project? in
            guard let id = UUID(uuidString: dir.lastPathComponent) else { return nil }
            return try? load(id: id)
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    public func delete(id: UUID) throws {
        let dir = directory(for: id)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
    }

    /// Moves (not copies) a file into the project's Media folder under a unique name.
    public func adoptMedia(at url: URL, projectID: UUID) throws -> String {
        let media = mediaDirectory(for: projectID)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        try fm.moveItem(at: url, to: media.appendingPathComponent(name))
        return name
    }
}
