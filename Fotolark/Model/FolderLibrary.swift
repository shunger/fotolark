import CoreServices
import Foundation
import FotolarkKit
import Observation

/// The folders the person asked Fotolark to watch, kept between launches.
///
/// Access is stored as security-scoped bookmarks, so the sandbox lets Fotolark back
/// into each folder after a restart without asking again.
@MainActor @Observable
final class FolderLibrary {
    struct Root: Identifiable, Codable, Equatable {
        var id = UUID()
        var bookmark: Data
        /// Last known path, shown if the bookmark can't be resolved (e.g. drive unplugged).
        var path: String
    }

    private(set) var roots: [Root] = []
    /// Folders with photos, per root, in display order.
    private(set) var folders: [Root.ID: [ScannedFolder]] = [:]
    private(set) var resolvedURLs: [Root.ID: URL] = [:]
    private(set) var isScanning = false

    /// Called (on the main actor) with the folders that changed on disk.
    var onFoldersChanged: ((Set<URL>) -> Void)?

    private let saveURL: URL
    private var watcher: FolderWatcher?
    private var rescanTask: Task<Void, Never>?

    init(supportDirectory: URL) {
        saveURL = supportDirectory.appendingPathComponent("Folders.json")
        if let data = try? Data(contentsOf: saveURL), let saved = try? JSONDecoder().decode([Root].self, from: data) {
            roots = saved
        }
        for i in roots.indices { resolve(&roots[i]) }
        persist()
        rescanAll()
        restartWatcher()
    }

    // MARK: Adding and removing

    /// Adds a folder (from a drop or the open panel, which grant access for now) and
    /// returns its URL. Adding a folder that's already watched, or is inside one, just
    /// returns it.
    @discardableResult
    func add(_ url: URL) -> URL {
        let path = url.standardizedFileURL.path
        if resolvedURLs.values.contains(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            return url
        }
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return url
        }
        var root = Root(bookmark: bookmark, path: path)
        resolve(&root)
        roots.append(root)
        persist()
        rescan(root.id)
        restartWatcher()
        return url
    }

    func remove(_ id: Root.ID) {
        resolvedURLs[id]?.stopAccessingSecurityScopedResource()
        resolvedURLs[id] = nil
        folders[id] = nil
        roots.removeAll { $0.id == id }
        persist()
        restartWatcher()
    }

    func name(of root: Root) -> String {
        (resolvedURLs[root.id] ?? URL(fileURLWithPath: root.path)).lastPathComponent
    }

    func isAvailable(_ root: Root) -> Bool { resolvedURLs[root.id] != nil }

    // MARK: Scanning

    func rescanAll() {
        for root in roots { rescan(root.id) }
    }

    private func rescan(_ id: Root.ID) {
        guard let url = resolvedURLs[id] else { return }
        isScanning = true
        Task {
            let found = await Task.detached(priority: .utility) { PhotoScanner.folders(under: url) }.value
            folders[id] = found
            isScanning = false
        }
    }

    // MARK: Bookmarks

    private func resolve(_ root: inout Root) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: root.bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else { return }
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                                                    includingResourceValuesForKeys: nil, relativeTo: nil) {
            root.bookmark = fresh
        }
        root.path = url.path
        resolvedURLs[root.id] = url
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(roots).write(to: saveURL, options: .atomic)
    }

    // MARK: Watching for changes made in Finder

    private func restartWatcher() {
        watcher = nil
        let paths = Array(resolvedURLs.values)
        guard !paths.isEmpty else { return }
        watcher = FolderWatcher(urls: paths) { [weak self] changed in
            self?.filesChanged(changed)
        }
    }

    private func filesChanged(_ changed: Set<URL>) {
        // Fotolark's own sidecar writes land here too; re-listing a folder is cheap and
        // keeps the selection, so there's no need to tell them apart.
        onFoldersChanged?(changed)
        rescanTask?.cancel()
        rescanTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            rescanAll()
        }
    }
}

/// Reports folders whose contents changed, using FSEvents (Mac-only, so it lives in the
/// app rather than FotolarkKit).
final class FolderWatcher: @unchecked Sendable {  // events arrive on the main queue
    private var stream: FSEventStreamRef?
    private let handler: @MainActor (Set<URL>) -> Void

    init(urls: [URL], handler: @escaping @MainActor (Set<URL>) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let folders = Set(array.prefix(count).map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL })
            MainActor.assumeIsolated { watcher.handler(folders) }
        }
        stream = FSEventStreamCreate(nil, callback, &context, urls.map(\.path) as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                     UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
