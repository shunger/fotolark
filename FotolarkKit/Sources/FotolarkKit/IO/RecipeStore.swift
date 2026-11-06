import CryptoKit
import Foundation

/// Contents of a sidecar file. One sidecar serves every photo with the same base name
/// (IMG_0001.jpg and IMG_0001.heic both use IMG_0001.fotolark), keyed by file name.
public struct SidecarFile: Codable, Equatable, Sendable {
    public var format: String = "Fotolark edits"
    public var version: Int = 1
    public var photos: [String: EditRecipe] = [:]

    public init(photos: [String: EditRecipe] = [:]) {
        self.photos = photos
    }
}

/// Saves and loads edit recipes.
///
/// Recipes live in a sidecar file beside the photo. A sandboxed app opened on a single
/// photo may only write that sidecar because the app declares it as a related file
/// (`NSIsRelatedItemType` in Info.plist) and writes through `NSFileCoordinator` with a
/// file presenter naming the photo as the primary item. If that still fails, the recipe
/// goes to the app's own storage instead and moves to the sidecar on a later save.
public final class RecipeStore: @unchecked Sendable {
    public static let sidecarExtension = "fotolark"

    public enum Location: Equatable, Sendable {
        case sidecar(URL)
        case appStorage(URL)
        case removed
    }

    /// Where recipes go when the sidecar can't be written.
    public let fallbackDirectory: URL

    public init(fallbackDirectory: URL) {
        self.fallbackDirectory = fallbackDirectory
    }

    public static func sidecarURL(for photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension(sidecarExtension)
    }

    // MARK: Load

    public func load(for photo: URL) -> EditRecipe? {
        // A fallback copy exists only when the last sidecar write failed, so it is newer.
        if let data = try? Data(contentsOf: fallbackURL(for: photo)),
           let entry = try? JSONDecoder().decode(FallbackEntry.self, from: data) {
            return entry.recipe
        }
        let sidecar = Self.sidecarURL(for: photo)
        guard let data = try? coordinatedRead(sidecar, primary: photo),
              let file = try? JSONDecoder().decode(SidecarFile.self, from: data)
        else { return nil }
        return file.photos[photo.lastPathComponent]
    }

    // MARK: Save

    /// Saves `recipe` for `photo`. An empty recipe removes the photo's entry, and the
    /// sidecar file itself once no photo uses it.
    @discardableResult
    public func save(_ recipe: EditRecipe, for photo: URL) throws -> Location {
        let sidecar = Self.sidecarURL(for: photo)
        do {
            try updateSidecar(sidecar, primary: photo) { file in
                file.photos[photo.lastPathComponent] = recipe.isEmpty ? nil : recipe
            }
            try? FileManager.default.removeItem(at: fallbackURL(for: photo))
            return recipe.isEmpty ? .removed : .sidecar(sidecar)
        } catch {
            let url = fallbackURL(for: photo)
            if recipe.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return .removed
            }
            try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
            let entry = FallbackEntry(path: photo.path, recipe: recipe)
            try Self.encoder.encode(entry).write(to: url, options: .atomic)
            return .appStorage(url)
        }
    }

    // MARK: Internals

    struct FallbackEntry: Codable {
        var path: String
        var recipe: EditRecipe
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    func fallbackURL(for photo: URL) -> URL {
        let digest = SHA256.hash(data: Data(photo.standardizedFileURL.path.utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return fallbackDirectory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func coordinatedRead(_ url: URL, primary: URL) throws -> Data {
        let presenter = RelatedFilePresenter(primary: primary, related: url)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var coordError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadNoSuchFile))
        NSFileCoordinator(filePresenter: presenter).coordinate(readingItemAt: url, options: [], error: &coordError) { url in
            result = Result { try Data(contentsOf: url) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    private func updateSidecar(_ url: URL, primary: URL, change: (inout SidecarFile) -> Void) throws {
        let presenter = RelatedFilePresenter(primary: primary, related: url)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: [], error: &coordError) { url in
            do {
                var file = SidecarFile()
                if let data = try? Data(contentsOf: url) {
                    // Never overwrite a sidecar we can't understand (e.g. from a newer version).
                    file = try JSONDecoder().decode(SidecarFile.self, from: data)
                }
                change(&file)
                if file.photos.isEmpty {
                    guard FileManager.default.fileExists(atPath: url.path) else { return }
                    // If the sandbox refuses the delete, leave an empty sidecar instead.
                    if (try? FileManager.default.removeItem(at: url)) == nil {
                        try Self.encoder.encode(file).write(to: url)
                    }
                } else {
                    // Not atomic: the sandbox allows the related file itself, not a temporary beside it.
                    try Self.encoder.encode(file).write(to: url)
                }
            } catch {
                writeError = error
            }
        }
        if let error = coordError ?? writeError { throw error }
    }
}

/// Tells the system that the sidecar belongs to the photo the person opened.
/// Related-file access is a macOS sandbox feature; on iPad and iPhone the presenter
/// just names the sidecar (Phase 6 will use the Files app's own permissions).
final class RelatedFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    #if os(macOS)
    let primaryPresentedItemURL: URL?
    #endif
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()

    init(primary: URL, related: URL) {
        #if os(macOS)
        primaryPresentedItemURL = primary
        #endif
        presentedItemURL = related
    }
}
