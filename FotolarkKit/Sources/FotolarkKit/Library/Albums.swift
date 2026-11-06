import Foundation

/// A named collection of photos from any folders. The files don't move; an album just
/// remembers where they are.
public struct Album: Codable, Identifiable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        /// Where the photo was last seen.
        public var path: String
        /// Finds the photo again after it is moved or renamed in Finder.
        public var bookmark: Data?
    }

    public var id: UUID
    public var name: String
    public var items: [Item]

    public init(id: UUID = UUID(), name: String, items: [Item] = []) {
        self.id = id
        self.name = name
        self.items = items
    }

    public func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return items.contains { $0.path == path }
    }
}

/// Every album, saved in Fotolark's own storage. Safe to use from any thread.
public final class AlbumStore: @unchecked Sendable {
    private var _albums: [Album]
    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        _albums = (try? JSONDecoder().decode([Album].self, from: Data(contentsOf: fileURL))) ?? []
    }

    public var albums: [Album] { lock.withLock { _albums } }

    public func album(_ id: Album.ID) -> Album? { albums.first { $0.id == id } }

    @discardableResult
    public func create(named name: String, with photos: [URL] = []) -> Album {
        var album = Album(name: Self.cleanName(name))
        album.items = photos.map(Self.item)
        lock.withLock { _albums.append(album) }
        save()
        return album
    }

    public func rename(_ id: Album.ID, to name: String) {
        let clean = Self.cleanName(name)
        guard !clean.isEmpty else { return }
        change(id) { $0.name = clean }
    }

    public func delete(_ id: Album.ID) {
        lock.withLock { _albums.removeAll { $0.id == id } }
        save()
    }

    /// Adds photos that aren't in the album yet, at the end.
    public func add(_ photos: [URL], to id: Album.ID) {
        change(id) { album in
            for url in photos where !album.contains(url) { album.items.append(Self.item(for: url)) }
        }
    }

    public func remove(_ photos: [URL], from id: Album.ID) {
        let paths = Set(photos.map { $0.standardizedFileURL.path })
        change(id) { $0.items.removeAll { paths.contains($0.path) } }
    }

    /// The album's photos where they are now. A photo moved or renamed since it was
    /// added is found through its bookmark, and its new place is remembered; photos
    /// that can't be found (deleted, or on a drive that isn't connected) are left out.
    public func photos(in id: Album.ID) -> [URL] {
        guard let album = album(id) else { return [] }
        var found: [URL] = []
        var updated = album.items
        for (i, item) in album.items.enumerated() {
            if FileManager.default.fileExists(atPath: item.path) {
                found.append(URL(fileURLWithPath: item.path))
            } else if let data = item.bookmark, let url = Self.resolve(data),
                      FileManager.default.fileExists(atPath: url.path) {
                found.append(url)
                updated[i] = Self.item(for: url)
            }
        }
        if updated != album.items { change(id) { $0.items = updated } }
        return found
    }

    /// Albums that hold `url`.
    public func albums(containing url: URL) -> [Album] {
        albums.filter { $0.contains(url) }
    }

    // MARK: Internals

    private func change(_ id: Album.ID, _ body: (inout Album) -> Void) {
        lock.withLock {
            guard let i = _albums.firstIndex(where: { $0.id == id }) else { return }
            body(&_albums[i])
        }
        save()
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(_albums) }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: fileURL, options: .atomic)
    }

    static func cleanName(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled Album" : t
    }

    static func item(for url: URL) -> Album.Item {
        let u = url.standardizedFileURL
        return Album.Item(path: u.path, bookmark: try? u.bookmarkData(options: bookmarkOptions,
                                                                     includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    private static var bookmarkOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        [.minimalBookmark]
        #endif
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        #if os(macOS)
        // Needed for a photo outside the watched folders (opened on its own). Kept open
        // while Fotolark runs.
        _ = url.startAccessingSecurityScopedResource()
        #endif
        return url.standardizedFileURL
    }
}
