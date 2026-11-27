import Foundation

// MARK: - Looks

/// A colour look: a LUT the picture plays through, one of the app's own or a `.cube` file the
/// user brought in. `id` names it (`builtin:<name>` or `cube:<file>`); `name` is kept too, so a
/// look whose file has gone can still be named. `intensity` mixes it with the clean picture.
public struct Look: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// 0 (the clean picture) … 1 (the full look).
    public var intensity: Double

    public init(id: String, name: String, intensity: Double = 1) {
        self.id = id
        self.name = name
        self.intensity = min(1, max(0, intensity))
    }
}

/// Gives a piece of media a look, or takes it off (nil). Every clip of it plays through it.
public struct SetSourceLookCommand: EditingCommand {
    public let sourceID: UUID
    public let look: Look?

    public init(sourceID: UUID, look: Look?) {
        self.sourceID = sourceID
        self.look = look
    }

    public var actionName: String { look == nil ? "Remove Look" : "Set Look" }

    public func apply(to project: inout Project) throws {
        guard let i = project.sources.firstIndex(where: { $0.id == sourceID }) else { throw EditError.clipNotFound }
        project.sources[i].look = look
    }
}

extension Project {
    /// Whether any media has a look, so the picture needs drawing through them.
    public var usesLooks: Bool { sources.contains { $0.look != nil } }
}
