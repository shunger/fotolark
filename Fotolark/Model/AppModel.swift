import AppKit
import FotolarkKit
import Observation
import UniformTypeIdentifiers

/// What's on screen: a folder (or the photos opened one by one), the selection in the
/// grid, and the photo being edited.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    enum Source: Hashable {
        case folder(URL)
        /// Photos opened one at a time (from Finder or the Open panel), not as a folder.
        case opened
    }

    var source: Source? {
        didSet { if source != oldValue { selection = []; reloadPhotos() } }
    }

    /// Photos of the current source, in the chosen order.
    private(set) var photos: [ScannedPhoto] = []
    private(set) var openedPhotos: [URL] = []
    var selection: Set<URL> = []
    /// Edits of the photos on screen, for thumbnails.
    private(set) var recipes: [URL: EditRecipe] = [:]
    private(set) var isLoadingPhotos = false
    private(set) var editor: PhotoEditor?
    var errorMessage: String?

    var sortOrder: PhotoSortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
            photos = sortOrder.sorted(photos, dates: dates.dates(for: photos))
        }
    }

    /// Thumbnail size in the grid, in points.
    var thumbnailSize: Double {
        didSet { UserDefaults.standard.set(thumbnailSize, forKey: "thumbnailSize") }
    }

    let engine = EditEngine()
    let store: RecipeStore
    let thumbnails: ThumbnailStore
    let fileOperations: PhotoFileOperations
    let library: FolderLibrary
    let backupDirectory: URL
    private let dates: DateTakenCache
    private var loadGeneration = 0

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fotolark", isDirectory: true)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fotolark", isDirectory: true)
        store = RecipeStore(fallbackDirectory: support.appendingPathComponent("Recipes", isDirectory: true))
        store.usesSidecars = !UserDefaults.standard.bool(forKey: "storeEditsInLibrary")
        backupDirectory = support.appendingPathComponent("Backups", isDirectory: true)
        thumbnails = ThumbnailStore(diskDirectory: caches.appendingPathComponent("Thumbnails"), engine: engine)
        fileOperations = PhotoFileOperations(store: store)
        library = FolderLibrary(supportDirectory: support)
        dates = DateTakenCache(fileURL: caches.appendingPathComponent("DatesTaken.json"))
        sortOrder = PhotoSortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .dateTaken
        let size = UserDefaults.standard.double(forKey: "thumbnailSize")
        thumbnailSize = size > 0 ? size : 160

        library.onFoldersChanged = { [weak self] changed in self?.foldersChanged(changed) }
        if let first = library.roots.first, let url = library.resolvedURLs[first.id] {
            source = .folder(url)
            reloadPhotos()
        }
    }

    // MARK: Opening

    /// Folders become watched folders; single photos open straight in the editor.
    func open(_ urls: [URL]) {
        var files: [URL] = []
        var lastFolder: URL?
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                lastFolder = library.add(url)
            } else if ImageLoader.canOpen(url) {
                files.append(url.standardizedFileURL)
            }
        }
        if !files.isEmpty {
            let known = Set(openedPhotos)
            openedPhotos += files.filter { !known.contains($0) }
            closeEditor()
            source = .opened
            reloadPhotos { [weak self] in self?.openEditor(files[0]) }
        } else if let folder = lastFolder {
            closeEditor()
            source = .folder(folder.standardizedFileURL)
        } else if !urls.isEmpty {
            errorMessage = "Fotolark couldn’t find any photos it can open there."
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ImageLoader.readableTypes
        panel.message = "Choose photos, or a folder to add to the sidebar"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    func addFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders of photos. Fotolark shows them in the sidebar and keeps them up to date."
        if panel.runModal() == .OK { open(panel.urls) }
    }

    // MARK: Loading the grid

    /// Re-lists the current source in the background, keeping the selection.
    func reloadPhotos(then completion: (() -> Void)? = nil) {
        loadGeneration += 1
        let generation = loadGeneration
        guard let source else {
            photos = []
            completion?()
            return
        }
        isLoadingPhotos = true
        let opened = openedPhotos
        let store = store
        Task {
            let (found, recipes) = await Task.detached(priority: .userInitiated) { () -> ([ScannedPhoto], [URL: EditRecipe]) in
                let found: [ScannedPhoto]
                switch source {
                case .folder(let url): found = PhotoScanner.photos(in: url)
                case .opened: found = opened.compactMap(Self.scan)
                }
                return (found, store.recipes(for: found.map(\.url)))
            }.value
            guard generation == loadGeneration else { return }
            self.recipes = recipes
            photos = sortOrder.sorted(found, dates: dates.dates(for: found))
            selection = selection.intersection(found.map(\.url))
            isLoadingPhotos = false
            completion?()
            loadDatesTaken(for: found, generation: generation)
        }
    }

    nonisolated private static func scan(_ url: URL) -> ScannedPhoto? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]) else {
            return nil
        }
        return ScannedPhoto(url: url, fileSize: Int64(v.fileSize ?? 0),
                            modified: v.contentModificationDate ?? .distantPast,
                            created: v.creationDate ?? .distantPast)
    }

    /// Reads capture dates the cache doesn't have yet, then re-sorts once.
    private func loadDatesTaken(for found: [ScannedPhoto], generation: Int) {
        let missing = found.filter { !dates.has($0) }
        guard !missing.isEmpty else { return }
        let dates = dates
        Task {
            await Task.detached(priority: .utility) {
                for photo in missing { dates.set(PhotoMetadata.dateTaken(photo.url), for: photo) }
                dates.save()
            }.value
            guard generation == loadGeneration, sortOrder == .dateTaken else { return }
            photos = sortOrder.sorted(photos, dates: dates.dates(for: photos))
        }
    }

    private func foldersChanged(_ changed: Set<URL>) {
        guard case .folder(let current) = source else { return }
        let path = current.standardizedFileURL.path
        guard changed.contains(where: { $0.path == path || path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path) }) else {
            return
        }
        reloadPhotos { [weak self] in
            guard let self, let editor else { return }
            if !FileManager.default.fileExists(atPath: editor.url.path) { closeEditor() }
        }
    }

    // MARK: Editing

    func openEditor(_ url: URL) {
        editor?.saveNow()
        zoomScale = nil
        do {
            let e = try PhotoEditor(url: url, engine: engine, store: store)
            e.onSave = { [weak self] url, recipe in
                self?.recipes[url] = recipe.isEmpty ? nil : recipe
            }
            editor = e
            selection = [url]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Back to the grid, with the edited photo selected.
    func closeEditor() {
        guard let editor else { return }
        editor.saveNow()
        selection = [editor.url]
        self.editor = nil
    }

    func openSelection() {
        if let url = photos.first(where: { selection.contains($0.url) })?.url { openEditor(url) }
    }

    private var editorIndex: Int? {
        guard let url = editor?.url else { return nil }
        return photos.firstIndex { $0.url == url }
    }

    var canGoNext: Bool { editorIndex.map { $0 < photos.count - 1 } ?? false }
    var canGoPrevious: Bool { editorIndex.map { $0 > 0 } ?? false }
    var positionText: String? {
        guard let i = editorIndex, photos.count > 1 else { return nil }
        return "\(i + 1) of \(photos.count)"
    }

    func next() { if canGoNext, let i = editorIndex { openEditor(photos[i + 1].url) } }
    func previous() { if canGoPrevious, let i = editorIndex { openEditor(photos[i - 1].url) } }

    /// Opens the photo again from disk, e.g. after saving over it.
    func reloadCurrent() {
        guard let url = editor?.url else { return }
        editor = nil
        reloadPhotos { [weak self] in self?.openEditor(url) }
    }

    // MARK: Window state

    enum Sheet: String, Identifiable {
        case export, resize, rename
        var id: String { rawValue }
    }

    var sheet: Sheet?
    var isConfirmingOverwrite = false

    /// Points per image pixel; nil fits the photo to the window.
    var zoomScale: CGFloat?
    /// Reported by the canvas.
    var fitScale: CGFloat = 1
    var displayScale: CGFloat = 2

    /// 100% = one photo pixel per screen pixel.
    var actualSizeScale: CGFloat { 1 / displayScale }

    func setZoom(_ scale: CGFloat) {
        let clamped = min(scale, actualSizeScale * 8)
        zoomScale = clamped <= fitScale * 1.001 ? nil : clamped
    }

    func zoomIn() { setZoom((zoomScale ?? fitScale) * 1.5) }
    func zoomOut() { setZoom((zoomScale ?? fitScale) / 1.5) }
    func zoomToFit() { zoomScale = nil }
    func zoomToActualSize() { setZoom(actualSizeScale) }

    // MARK: File operations

    /// The photos a file command acts on: the one being edited, or the grid selection.
    var targetPhotos: [URL] {
        if let editor { return [editor.url] }
        return photos.map(\.url).filter { selection.contains($0) }
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(targetPhotos)
    }

    func rename(_ url: URL, to name: String) {
        do {
            let wasEditing = editor?.url == url
            if wasEditing { closeEditor() }
            let renamed = try fileOperations.rename(url, to: name)
            if let i = openedPhotos.firstIndex(of: url) { openedPhotos[i] = renamed }
            reloadPhotos { [weak self] in
                self?.selection = [renamed]
                if wasEditing { self?.openEditor(renamed) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func moveOrCopyTargets(copy: Bool) {
        let targets = targetPhotos
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = copy ? "Copy Here" : "Move Here"
        panel.message = "Choose where to \(copy ? "copy" : "move") \(targets.count == 1 ? "the photo" : "\(targets.count) photos")."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            if !copy { closeEditor() }
            if copy {
                try fileOperations.copy(targets, to: folder)
            } else {
                let moved = try fileOperations.move(targets, to: folder)
                openedPhotos = openedPhotos.map { url in targets.firstIndex(of: url).map { moved[$0] } ?? url }
            }
            reloadPhotos()
        } catch {
            errorMessage = error.localizedDescription
            reloadPhotos()
        }
    }

    func moveTargetsToTrash() {
        let targets = targetPhotos
        guard !targets.isEmpty else { return }
        // Keep the grid position: select the photo after the last one trashed.
        let after = photos.drop { !targets.contains($0.url) }.first { !targets.contains($0.url) }?.url
        if editor != nil { editor?.saveNow(); editor = nil }
        var failed: [String] = []
        for url in targets {
            do { try fileOperations.moveToTrash(url) } catch { failed.append(url.lastPathComponent) }
        }
        openedPhotos.removeAll { targets.contains($0) }
        reloadPhotos { [weak self] in self?.selection = after.map { [$0] } ?? [] }
        if !failed.isEmpty {
            errorMessage = "Couldn’t move \(failed.joined(separator: ", ")) to the Trash."
        }
    }

    // MARK: Copy and paste edits

    /// Tone and color edits copied with Copy Edits.
    private(set) var copiedEdits: EditRecipe?
    /// Progress while pasting onto many photos.
    private(set) var pasteProgress: (done: Int, total: Int)?

    /// The edits of the photo being edited, or of the one selected photo.
    var editsToCopy: EditRecipe? {
        let recipe = editor?.recipe ?? (targetPhotos.count == 1 ? recipes[targetPhotos[0]] : nil)
        guard let edits = recipe?.pastableEdits, !edits.isEmpty else { return nil }
        return edits
    }

    func copyEdits() {
        copiedEdits = editsToCopy
    }

    var canPasteEdits: Bool { copiedEdits != nil && !targetPhotos.isEmpty && pasteProgress == nil }

    /// Pastes onto the photo being edited (undoable there), or onto every selected photo.
    func pasteEdits() {
        guard let copied = copiedEdits else { return }
        if let editor {
            editor.paste(copied)
            return
        }
        let targets = targetPhotos
        guard !targets.isEmpty else { return }
        let store = store
        let engine = engine
        let current = recipes
        pasteProgress = (0, targets.count)
        Task {
            var failed = 0
            for (i, url) in targets.enumerated() {
                let result = await Task.detached(priority: .userInitiated) { () -> EditRecipe? in
                    guard let preview = try? ImageLoader.loadPreview(url, maxPixelSize: 1024) else { return nil }
                    let target = (current[url] ?? store.load(for: url) ?? EditRecipe()).pasting(copied)
                    let recipe = engine.recomputingAutoFixes(target, for: preview)
                    return (try? store.save(recipe, for: url)) != nil ? recipe : nil
                }.value
                if let result { recipes[url] = result.isEmpty ? nil : result } else { failed += 1 }
                pasteProgress = (i + 1, targets.count)
            }
            pasteProgress = nil
            if failed > 0 { errorMessage = "Couldn’t paste edits onto \(failed) of the photos." }
        }
    }

    // MARK: Settings

    var storesEditsInLibrary = UserDefaults.standard.bool(forKey: "storeEditsInLibrary") {
        didSet {
            store.usesSidecars = !storesEditsInLibrary
            UserDefaults.standard.set(storesEditsInLibrary, forKey: "storeEditsInLibrary")
        }
    }

    // MARK: Save over original

    func saveOverOriginal() {
        guard let editor else { return }
        editor.saveNow()
        let url = editor.url
        let recipe = editor.history.current
        let engine = engine
        let backups = backupDirectory
        let store = store
        editor.isBusy = true
        Task {
            do {
                try await Task.detached {
                    _ = try OriginalOverwriter.overwrite(photo: url, recipe: recipe, engine: engine,
                                                         backupDirectory: backups)
                    // The edits are now part of the file itself.
                    try store.save(EditRecipe(), for: url)
                }.value
                recipes[url] = nil
                reloadCurrent()
            } catch {
                editor.isBusy = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func showBackupsInFinder() {
        try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([backupDirectory])
    }
}

/// Capture dates read from photos, kept on disk so sorting a big folder by date is
/// instant the second time. Entries are tied to the file's modification date.
final class DateTakenCache: @unchecked Sendable {
    private struct Entry: Codable {
        var modified: Double
        var date: Double?
    }

    private var entries: [String: Entry]
    private let lock = NSLock()
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        entries = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    func has(_ photo: ScannedPhoto) -> Bool {
        lock.withLock { entries[photo.url.path]?.modified == photo.modified.timeIntervalSince1970 }
    }

    func set(_ date: Date?, for photo: ScannedPhoto) {
        lock.withLock {
            entries[photo.url.path] = Entry(modified: photo.modified.timeIntervalSince1970,
                                            date: date?.timeIntervalSince1970)
        }
    }

    /// Known capture dates, keyed by the photos' own URLs.
    func dates(for photos: [ScannedPhoto]) -> [URL: Date] {
        lock.withLock {
            var out: [URL: Date] = [:]
            for p in photos {
                if let d = entries[p.url.path]?.date { out[p.url] = Date(timeIntervalSince1970: d) }
            }
            return out
        }
    }

    func save() {
        let data = lock.withLock { try? JSONEncoder().encode(entries) }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: fileURL, options: .atomic)
    }
}
