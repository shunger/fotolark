import CryptoKit
import Foundation

/// Contents of a sidecar file. One sidecar serves every photo with the same base name
/// (IMG_0001.jpg and IMG_0001.heic both use IMG_0001.fotolark), keyed by file name.
public struct SidecarFile: Codable, Equatable, Sendable {
    public var format: String = "Fotolark edits"
    public var version: Int = 1
    public var photos: [String: EditRecipe] = [:]
    /// Ratings, flags and tags (left out of the file when there are none).
    public var labels: [String: PhotoLabels] = [:]

    public init(photos: [String: EditRecipe] = [:], labels: [String: PhotoLabels] = [:]) {
        self.photos = photos
        self.labels = labels
    }

    enum CodingKeys: String, CodingKey { case format, version, photos, labels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? "Fotolark edits"
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        photos = try c.decodeIfPresent([String: EditRecipe].self, forKey: .photos) ?? [:]
        labels = try c.decodeIfPresent([String: PhotoLabels].self, forKey: .labels) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(version, forKey: .version)
        try c.encode(photos, forKey: .photos)
        if !labels.isEmpty { try c.encode(labels, forKey: .labels) }
    }

    var isEmpty: Bool { photos.isEmpty && labels.isEmpty }

    func record(named name: String) -> PhotoRecord {
        PhotoRecord(recipe: photos[name] ?? EditRecipe(), labels: labels[name] ?? PhotoLabels())
    }

    mutating func set(_ record: PhotoRecord, named name: String) {
        photos[name] = record.recipe.isEmpty ? nil : record.recipe
        labels[name] = record.labels.isEmpty ? nil : record.labels
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

    /// Where recipes go when the sidecar can't be written, or when the person chose
    /// to keep edits in Fotolark's own library instead of beside the photos.
    public let fallbackDirectory: URL

    /// True (the default) to write sidecar files beside photos; false to keep every
    /// recipe in `fallbackDirectory`. Existing sidecars are still read either way.
    public var usesSidecars: Bool {
        get { lock.withLock { _usesSidecars } }
        set { lock.withLock { _usesSidecars = newValue } }
    }
    private var _usesSidecars = true
    private let lock = NSLock()
    private let writeLock = NSRecursiveLock()

    public init(fallbackDirectory: URL) {
        self.fallbackDirectory = fallbackDirectory
    }

    public static func sidecarURL(for photo: URL) -> URL {
        photo.deletingPathExtension().appendingPathExtension(sidecarExtension)
    }

    // MARK: Load

    public func load(for photo: URL) -> EditRecipe? {
        let recipe = loadRecord(for: photo).recipe
        return recipe.isEmpty ? nil : recipe
    }

    public func loadLabels(for photo: URL) -> PhotoLabels {
        loadRecord(for: photo).labels
    }

    /// The photo's edits and info (empty if it has none).
    public func loadRecord(for photo: URL) -> PhotoRecord {
        // A fallback copy exists only when the last sidecar write failed, so it is newer.
        if let record = fallbackRecord(for: photo) { return record }
        let sidecar = Self.sidecarURL(for: photo)
        guard let data = try? coordinatedRead(sidecar, primary: photo),
              let file = try? JSONDecoder().decode(SidecarFile.self, from: data)
        else { return PhotoRecord() }
        return file.record(named: photo.lastPathComponent)
    }

    /// Recipes for many photos at once, e.g. a whole folder for its thumbnails. Photos
    /// without edits are left out.
    public func recipes(for photos: [URL]) -> [URL: EditRecipe] {
        records(for: photos).compactMapValues { $0.recipe.isEmpty ? nil : $0.recipe }
    }

    /// Edits and info for many photos at once. Reads each sidecar file in the photos'
    /// folders once instead of once per photo. Photos with neither are left out.
    public func records(for photos: [URL]) -> [URL: PhotoRecord] {
        var result: [URL: PhotoRecord] = [:]
        let byFolder = Dictionary(grouping: photos) { $0.deletingLastPathComponent() }
        let hasFallbacks = FileManager.default.fileExists(atPath: fallbackDirectory.path)
        for (folder, inFolder) in byFolder {
            var sidecars: [String: SidecarFile] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == Self.sidecarExtension {
                if let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(SidecarFile.self, from: data) {
                    sidecars[url.deletingPathExtension().lastPathComponent] = file
                }
            }
            for photo in inFolder {
                let record = (hasFallbacks ? fallbackRecord(for: photo) : nil)
                    ?? sidecars[photo.deletingPathExtension().lastPathComponent]?.record(named: photo.lastPathComponent)
                if let record, !record.isEmpty { result[photo] = record }
            }
        }
        return result
    }

    // MARK: Save

    /// Saves `recipe` for `photo`, keeping its rating, flag and tags. An empty record
    /// removes the photo's entry, and the sidecar file itself once no photo uses it.
    @discardableResult
    public func save(_ recipe: EditRecipe, for photo: URL) throws -> Location {
        try update(photo) { $0.recipe = recipe }
    }

    /// Saves the photo's rating, flag and tags, keeping its edits.
    @discardableResult
    public func saveLabels(_ labels: PhotoLabels, for photo: URL) throws -> Location {
        try update(photo) { $0.labels = labels }
    }

    /// Replaces everything kept about the photo.
    @discardableResult
    public func saveRecord(_ record: PhotoRecord, for photo: URL) throws -> Location {
        try update(photo) { $0 = record }
    }

    /// Reads, changes and writes the photo's record in one step, so saving the edits
    /// and changing the rating at the same moment can't undo one another.
    @discardableResult
    public func update(_ photo: URL, change: (inout PhotoRecord) -> Void) throws -> Location {
        try writeLock.withLock {
            let sidecar = Self.sidecarURL(for: photo)
            let name = photo.lastPathComponent
            let fallback = fallbackRecord(for: photo)
            if !usesSidecars {
                // Lift any older sidecar entry into the library so it can't resurface.
                var old: PhotoRecord?
                try? updateSidecar(sidecar, primary: photo) { file in
                    old = file.record(named: name)
                    file.set(PhotoRecord(), named: name)
                }
                var record = fallback ?? old ?? PhotoRecord()
                change(&record)
                return try saveToLibrary(record, for: photo)
            }
            var changed = PhotoRecord()
            do {
                try updateSidecar(sidecar, primary: photo) { file in
                    var record = fallback ?? file.record(named: name)
                    change(&record)
                    file.set(record, named: name)
                    changed = record
                }
                try? FileManager.default.removeItem(at: fallbackURL(for: photo))
                return changed.isEmpty ? .removed : .sidecar(sidecar)
            } catch {
                var record = fallback ?? loadRecord(for: photo)
                change(&record)
                return try saveToLibrary(record, for: photo)
            }
        }
    }

    /// Moves a photo's edits and info along with it after the file was renamed or moved.
    public func moveRecipe(from old: URL, to new: URL) throws {
        let record = loadRecord(for: old)
        guard !record.isEmpty else { return }
        try saveRecord(record, for: new)
        try saveRecord(PhotoRecord(), for: old)
    }

    /// Gives a copied photo the same edits and info as the original.
    public func copyRecipe(from source: URL, to copy: URL) throws {
        let record = loadRecord(for: source)
        guard !record.isEmpty else { return }
        try saveRecord(record, for: copy)
    }

    private func saveToLibrary(_ record: PhotoRecord, for photo: URL) throws -> Location {
        let url = fallbackURL(for: photo)
        if record.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return .removed
        }
        try FileManager.default.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
        let entry = FallbackEntry(path: photo.path, recipe: record.recipe, labels: record.labels)
        try Self.encoder.encode(entry).write(to: url, options: .atomic)
        return .appStorage(url)
    }

    private func fallbackRecord(for photo: URL) -> PhotoRecord? {
        guard let data = try? Data(contentsOf: fallbackURL(for: photo)),
              let entry = try? JSONDecoder().decode(FallbackEntry.self, from: data) else { return nil }
        return PhotoRecord(recipe: entry.recipe, labels: entry.labels ?? PhotoLabels())
    }

    // MARK: Internals

    struct FallbackEntry: Codable {
        var path: String
        var recipe: EditRecipe
        var labels: PhotoLabels?
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
                if file.isEmpty {
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
