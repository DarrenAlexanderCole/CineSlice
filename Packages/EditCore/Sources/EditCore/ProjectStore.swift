import Foundation

/// File-based project persistence:
///
///     <root>/<project-id>/project.json
///     <root>/<project-id>/Media/<uuid>.<ext>     imported copies (never modified)
///     <root>/<project-id>/Exports/...            rendered files
///     <root>/<project-id>/Cache/...              derived data (waveforms, processed voice); safe to delete
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
        cacheDirectory(for: projectID).appendingPathComponent("\(track.fileName).waveform")
    }

    /// Where one half of a source's split sound is kept. It's derived data: clearing the cache
    /// removes it and it is made again when needed. The name says which separator made it, so
    /// sound made by an earlier one is made again rather than reused.
    public func stemCacheURL(for source: SourceAsset, stem: SoundStem, projectID: UUID) -> URL {
        cacheDirectory(for: projectID)
            .appendingPathComponent("Voice", isDirectory: true)
            .appendingPathComponent("\(source.fileName).\(stem.rawValue).dbstiger-stereo.m4a")
    }

    /// A clip's split sound, or nil when it plays as recorded or the split hasn't been made yet.
    public func stemURLs(for clip: TimelineClip, source: SourceAsset, projectID: UUID) -> (voice: URL, scene: URL)? {
        guard clip.balance != nil else { return nil }
        let voice = stemCacheURL(for: source, stem: .voice, projectID: projectID)
        let scene = stemCacheURL(for: source, stem: .scene, projectID: projectID)
        guard fm.fileExists(atPath: voice.path), fm.fileExists(atPath: scene.path) else { return nil }
        return (voice, scene)
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

    // MARK: Storage

    /// Past this, the library suggests clearing space (10 GB).
    public static let storageWarningBytes: Int64 = 10_000_000_000

    /// How much space a project takes on disk.
    public func usage(for projectID: UUID) -> StorageUsage {
        let dir = directory(for: projectID)
        let media = Self.size(of: mediaDirectory(for: projectID))
        let exports = Self.size(of: exportsDirectory(for: projectID))
        let cache = Self.size(of: cacheDirectory(for: projectID))
        let total = Self.size(of: dir)
        return StorageUsage(
            media: media, exports: exports, cache: cache, other: max(0, total - media - exports - cache))
    }

    /// Deletes a project's rendered files. The project itself is untouched.
    public func clearExports(for projectID: UUID) throws {
        try removeIfPresent(exportsDirectory(for: projectID))
    }

    /// Deletes a project's derived data (waveforms); it is rebuilt when needed.
    public func clearCache(for projectID: UUID) throws {
        try removeIfPresent(cacheDirectory(for: projectID))
    }

    private func cacheDirectory(for projectID: UUID) -> URL {
        directory(for: projectID).appendingPathComponent("Cache", isDirectory: true)
    }

    private func removeIfPresent(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    /// Bytes on disk under `url` (a file or a folder); 0 when it doesn't exist.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        func bytes(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else {
                return 0
            }
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard
            let items = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return bytes(url) }
        var total = bytes(url)
        for case let item as URL in items { total += bytes(item) }
        return total
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

/// A project's footprint on disk, in bytes.
public struct StorageUsage: Equatable, Sendable {
    /// Its own copies of the imported footage and music; they go only with the project.
    public var media: Int64
    /// Rendered videos and their sync files.
    public var exports: Int64
    /// Derived data, rebuilt when needed.
    public var cache: Int64
    /// The project file and anything else.
    public var other: Int64

    public init(media: Int64 = 0, exports: Int64 = 0, cache: Int64 = 0, other: Int64 = 0) {
        self.media = media
        self.exports = exports
        self.cache = cache
        self.other = other
    }

    public var total: Int64 { media + exports + cache + other }
    /// What can be cleared without touching the project.
    public var clearable: Int64 { exports + cache }
}
