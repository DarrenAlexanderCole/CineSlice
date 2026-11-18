import Foundation

/// Snapshot-based undo. Projects are small metadata documents (media is
/// referenced, not embedded), so storing the pre-command state is cheap and
/// guarantees exact restoration.
public struct UndoStack: Sendable {
    public struct Entry: Sendable {
        public let actionName: String
        public let snapshot: Project
    }

    public private(set) var undoEntries: [Entry] = []
    public private(set) var redoEntries: [Entry] = []
    public var limit: Int

    public init(limit: Int = 200) { self.limit = limit }

    public var canUndo: Bool { !undoEntries.isEmpty }
    public var canRedo: Bool { !redoEntries.isEmpty }
    public var undoActionName: String? { undoEntries.last?.actionName }
    public var redoActionName: String? { redoEntries.last?.actionName }

    /// Applies the command. On error the project is left unchanged and nothing is recorded.
    public mutating func perform(_ command: EditingCommand, on project: inout Project, now: Date = Date()) throws {
        var working = project
        try command.apply(to: &working)
        guard working != project else { return }  // no-op edits don't pollute history
        working.modifiedAt = now
        undoEntries.append(Entry(actionName: command.actionName, snapshot: project))
        if undoEntries.count > limit { undoEntries.removeFirst(undoEntries.count - limit) }
        redoEntries.removeAll()
        project = working
    }

    /// Applies a follow-on change as part of the last step: no entry of its own, so undo takes it
    /// back together with that step (its snapshot is from before both), and redo restores both.
    public mutating func amend(_ command: EditingCommand, on project: inout Project) throws {
        try command.apply(to: &project)
    }

    @discardableResult
    public mutating func undo(_ project: inout Project) -> String? {
        guard let entry = undoEntries.popLast() else { return nil }
        redoEntries.append(Entry(actionName: entry.actionName, snapshot: project))
        project = entry.snapshot
        return entry.actionName
    }

    @discardableResult
    public mutating func redo(_ project: inout Project) -> String? {
        guard let entry = redoEntries.popLast() else { return nil }
        undoEntries.append(Entry(actionName: entry.actionName, snapshot: project))
        project = entry.snapshot
        return entry.actionName
    }

    public mutating func clear() {
        undoEntries.removeAll()
        redoEntries.removeAll()
    }
}
