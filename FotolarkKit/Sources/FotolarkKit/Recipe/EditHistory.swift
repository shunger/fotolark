import Foundation

/// Unlimited undo and redo for one photo. Every step stores the whole recipe, which is
/// small, so jumping to any point in the history is just picking an entry.
public struct EditHistory: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Identifiable {
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
}
