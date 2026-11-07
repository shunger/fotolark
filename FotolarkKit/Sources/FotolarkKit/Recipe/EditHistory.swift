import CryptoKit
import Foundation

/// Unlimited undo and redo for one photo. Every step stores the whole recipe, which is
/// small, so jumping to any point in the history is just picking an entry.
public struct EditHistory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let id: Int
        /// Short description for the History list, e.g. "Crop" or "Exposure".
        public let label: String
        public let recipe: EditRecipe
    }

    public private(set) var entries: [Entry]
    /// Index of the entry currently shown.
    public private(set) var index: Int
    private var nextID: Int

    public init(initial: EditRecipe, label: String = "Opened") {
        entries = [Entry(id: 0, label: label, recipe: initial)]
        index = 0
        nextID = 1
    }

    public var current: EditRecipe { entries[index].recipe }
    public var canUndo: Bool { index > 0 }
    public var canRedo: Bool { index < entries.count - 1 }
    public var undoLabel: String? { canUndo ? entries[index].label : nil }
    public var redoLabel: String? { canRedo ? entries[index + 1].label : nil }

    /// Records a new state. Anything that could have been redone is dropped.
    /// Returns false when the recipe did not change.
    @discardableResult
    public mutating func commit(_ recipe: EditRecipe, label: String) -> Bool {
        guard recipe != current else { return false }
        entries.removeSubrange((index + 1)...)
        entries.append(Entry(id: nextID, label: label, recipe: recipe))
        nextID += 1
        index = entries.count - 1
        return true
    }

    public mutating func undo() {
        if canUndo { index -= 1 }
    }

    public mutating func redo() {
        if canRedo { index += 1 }
    }

    public mutating func jump(to id: Entry.ID) {
        if let i = entries.firstIndex(where: { $0.id == id }) { index = i }
    }

    /// The same history keeping at most `limit` steps, dropping the oldest first (the
    /// current step is always kept).
    public func trimmed(to limit: Int) -> EditHistory {
        guard entries.count > limit, limit > 0 else { return self }
        let drop = min(entries.count - limit, index)
        guard drop > 0 else { return self }
        var copy = self
        copy.entries.removeFirst(drop)
        copy.index -= drop
        return copy
    }
}

/// Each photo's undo history, kept in Fotolark's own storage (not beside the photos) so
/// it survives quitting. A history is only used again while the photo's saved edits
/// still match where it left off.
public final class HistoryStore: @unchecked Sendable {
    public let directory: URL
    public static let stepLimit = 50

    public init(directory: URL) {
        self.directory = directory
    }

    public func save(_ history: EditHistory, for photo: URL) {
        let trimmed = history.trimmed(to: Self.stepLimit)
        let url = fileURL(for: photo)
        // A history with nothing to undo or redo isn't worth keeping.
        guard trimmed.entries.count > 1 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Saved(path: photo.standardizedFileURL.path, history: trimmed)).write(to: url, options: .atomic)
    }

    /// The photo's saved history, if its current step is `saved` (the edits on disk).
    public func load(for photo: URL, matching saved: EditRecipe) -> EditHistory? {
        guard let data = try? Data(contentsOf: fileURL(for: photo)),
              let s = try? JSONDecoder().decode(Saved.self, from: data),
              s.path == photo.standardizedFileURL.path, s.history.current == saved else { return nil }
        return s.history
    }

    struct Saved: Codable {
        var path: String
        var history: EditHistory
    }

    func fileURL(for photo: URL) -> URL {
        let digest = SHA256.hash(data: Data(photo.standardizedFileURL.path.utf8))
        return directory.appendingPathComponent(digest.prefix(16).map { String(format: "%02x", $0) }.joined())
            .appendingPathExtension("json")
    }
}
