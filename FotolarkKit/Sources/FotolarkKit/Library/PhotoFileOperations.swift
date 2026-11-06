import Foundation

/// Renames, moves, copies and trashes photos. A photo's edits always travel with it.
public struct PhotoFileOperations: Sendable {
    public let store: RecipeStore

    public init(store: RecipeStore) {
        self.store = store
    }

    public enum OperationError: LocalizedError, Equatable {
        case nameTaken(String)
        case invalidName

        public var errorDescription: String? {
            switch self {
            case .nameTaken(let name): "There is already a file named “\(name)” in that folder."
            case .invalidName: "That name can’t be used for a file. Names can’t be empty or contain “/” or “:”."
            }
        }
    }

    /// Renames a photo. `newName` may leave out the extension, which is then kept.
    @discardableResult
    public func rename(_ photo: URL, to newName: String) throws -> URL {
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            throw OperationError.invalidName
        }
        if (name as NSString).pathExtension.isEmpty { name += "." + photo.pathExtension }
        let target = photo.deletingLastPathComponent().appendingPathComponent(name)
        if target == photo { return photo }
        // Allow changing only the capitalization (the Mac's disks usually ignore case).
        let caseOnly = target.path.lowercased() == photo.path.lowercased()
        if !caseOnly, FileManager.default.fileExists(atPath: target.path) {
            throw OperationError.nameTaken(name)
        }
        try FileManager.default.moveItem(at: photo, to: target)
        try? store.moveRecipe(from: photo, to: target)
        return target
    }

    /// Moves photos into `folder`, adding " 2", " 3"… to names that are already used.
    @discardableResult
    public func move(_ photos: [URL], to folder: URL) throws -> [URL] {
        try photos.map { photo in
            let target = Self.availableURL(for: photo.lastPathComponent, in: folder)
            try FileManager.default.moveItem(at: photo, to: target)
            try? store.moveRecipe(from: photo, to: target)
            return target
        }
    }

    /// Copies photos into `folder`; each copy gets the original's edits.
    @discardableResult
    public func copy(_ photos: [URL], to folder: URL) throws -> [URL] {
        try photos.map { photo in
            let target = Self.availableURL(for: photo.lastPathComponent, in: folder)
            try FileManager.default.copyItem(at: photo, to: target)
            try? store.copyRecipe(from: photo, to: target)
            return target
        }
    }

    /// Moves a photo to the Trash (it can be put back from there). Its edits are kept in
    /// the sidecar until the photo's name is reused, so Put Back restores them too.
    @discardableResult
    public func moveToTrash(_ photo: URL) throws -> URL? {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: photo, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// `name` in `folder`, or "name 2", "name 3"… if taken.
    public static func availableURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            url = folder.appendingPathComponent(candidate)
            n += 1
        }
        return url
    }
}
