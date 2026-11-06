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
        /// Importing from a phone, camera, card or folder (key from `importKey`).
        case importing(String)
        /// An album's photos, from any folders.
        case album(Album.ID)
        /// Every photo in the watched folders, by month.
        case timeline
        /// Photos in the watched folders matching the search.
        case search(String)
        /// Faces found in the photos, grouped by person.
        case people
        /// Photos of a named person.
        case person(Person.ID)
        /// Photos of an unnamed group of faces (keyed by its first face).
        case faceGroup(UUID)
    }

    var source: Source? {
        didSet { if source != oldValue { comparing = nil; selection = []; reloadPhotos() } }
    }

    /// Photos of the current source, in the chosen order, after the filter.
    private(set) var photos: [ScannedPhoto] = []
    /// Before the filter.
    private var loadedPhotos: [ScannedPhoto] = []
    /// Month groups for the timeline; nil elsewhere.
    private(set) var sections: [GridSection]?
    /// Show only some photos (by stars, flag or tag).
    var filter = GridFilter() {
        didSet { if filter != oldValue { applyFilter() } }
    }
    var loadedCount: Int { loadedPhotos.count }
    private(set) var openedPhotos: [URL] = []
    var selection: Set<URL> = []
    /// Edits of the photos on screen, for thumbnails.
    private(set) var recipes: [URL: EditRecipe] = [:]
    /// Ratings, flags and tags of the photos on screen.
    private(set) var labels: [URL: PhotoLabels] = [:]
    private(set) var isLoadingPhotos = false
    private(set) var editor: PhotoEditor?
    var errorMessage: String?

    var sortOrder: PhotoSortOrder {
        didSet {
            UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder")
            guard source?.isFolderLike ?? false else { return }
            loadedPhotos = sortOrder.sorted(loadedPhotos, dates: dates.dates(for: loadedPhotos))
            applyFilter()
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
    let jobs = JobQueue()
    let devices = DeviceBrowser()
    let importHistory: ImportHistory
    let albumStore: AlbumStore
    let watchFolders: WatchFolders
    let index: LibraryIndex
    let analysis: AnalysisStore
    let peopleStore: PeopleStore
    /// Faces grouped by person, for the People view.
    private(set) var faceGroups: [FaceGroup] = []
    /// What the background indexer is doing, for the sidebar.
    private(set) var indexStatus: String?
    private var indexTask: Task<Void, Never>?
    private var textTask: Task<Void, Never>?
    private var reindexTask: Task<Void, Never>?
    /// The albums, kept in step with `albumStore` for the sidebar.
    private(set) var albums: [Album] = []
    private(set) var folderImports: [FolderImportSource] = []
    let promises: EditedPhotoPromise
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
        promises = EditedPhotoPromise(engine: engine)
        library = FolderLibrary(supportDirectory: support)
        dates = DateTakenCache(fileURL: caches.appendingPathComponent("DatesTaken.json"))
        importHistory = ImportHistory(fileURL: support.appendingPathComponent("ImportHistory.json"))
        albumStore = AlbumStore(fileURL: support.appendingPathComponent("Albums.json"))
        watchFolders = WatchFolders(supportDirectory: support, engine: engine)
        albums = albumStore.albums
        index = LibraryIndex(fileURL: caches.appendingPathComponent("LibraryIndex.json"))
        analysis = AnalysisStore(fileURL: caches.appendingPathComponent("Analysis.plist"))
        peopleStore = PeopleStore(fileURL: support.appendingPathComponent("People.json"))
        sortOrder = PhotoSortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .dateTaken
        let size = UserDefaults.standard.double(forKey: "thumbnailSize")
        thumbnailSize = size > 0 ? size : 160

        library.onFoldersChanged = { [weak self] changed in self?.foldersChanged(changed) }
        library.onRootsChanged = { [weak self] in self?.scheduleReindex(after: .milliseconds(200)) }
        jobs.onChange = { [weak self] in self?.reloadPhotos() }
        if let data = UserDefaults.standard.data(forKey: "export.presets"),
           let saved = try? JSONDecoder().decode([ExportPreset].self, from: data) {
            customPresets = saved
        }
        if let first = library.roots.first, let url = library.resolvedURLs[first.id] {
            source = .folder(url)
            reloadPhotos()
        }
        scheduleReindex(after: .seconds(1))
        recomputeFaceGroups()
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
        guard let source, source.isBrowsable else {
            photos = []
            loadedPhotos = []
            sections = nil
            completion?()
            return
        }
        isLoadingPhotos = true
        let opened = openedPhotos
        let store = store
        let albumStore = albumStore
        let index = index
        let facePhotos = photosForFaces(source)
        Task {
            let (found, records) = await Task.detached(priority: .userInitiated) { () -> ([ScannedPhoto], [URL: PhotoRecord]) in
                let found: [ScannedPhoto]
                switch source {
                case .folder(let url): found = PhotoScanner.photos(in: url)
                case .opened: found = opened.compactMap(Self.scan)
                case .album(let id): found = albumStore.photos(in: id).compactMap(Self.scan)
                case .timeline: found = index.all.map(\.scanned)
                case .person, .faceGroup: found = facePhotos.compactMap(Self.scan)
                case .people: found = []
                case .search(let text): found = index.search(text).map(\.scanned)
                case .importing: found = []
                }
                return (found, store.records(for: found.map(\.url)))
            }.value
            guard generation == loadGeneration else { return }
            self.recipes = records.compactMapValues { $0.recipe.isEmpty ? nil : $0.recipe }
            self.labels = records.compactMapValues { $0.labels.isEmpty ? nil : $0.labels }
            if case .album = source { albums = albumStore.albums }
            // The timeline and search results are newest first; folders follow the sort menu.
            loadedPhotos = source.isFolderLike ? sortOrder.sorted(found, dates: dates.dates(for: found)) : found
            applyFilter()
            isLoadingPhotos = false
            completion?()
            if source.isFolderLike { loadDatesTaken(for: found, generation: generation) }
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
            loadedPhotos = sortOrder.sorted(loadedPhotos, dates: dates.dates(for: loadedPhotos))
            applyFilter()
        }
    }

    /// Applies the filter, and groups the timeline by month.
    private func applyFilter() {
        photos = filter.isActive ? loadedPhotos.filter { filter.matches(labels[$0.url]) } : loadedPhotos
        selection = selection.intersection(photos.map(\.url))
        if source == .timeline {
            var groups: [GridSection] = []
            let calendar = Calendar.current
            let f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            for photo in photos {
                let date = index.entry(for: photo.url)?.date ?? photo.created
                let c = calendar.dateComponents([.year, .month], from: date)
                let id = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
                if groups.last?.id == id {
                    groups[groups.count - 1].urls.append(photo.url)
                } else {
                    groups.append(GridSection(id: id, title: f.string(from: date), urls: [photo.url]))
                }
            }
            sections = groups
        } else {
            sections = nil
        }
    }

    private func foldersChanged(_ changed: Set<URL>) {
        scheduleReindex(after: .seconds(4))
        if case .album = source {
            reloadPhotos()
            return
        }
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
        comparing = nil
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

    enum Sheet: Identifiable {
        case export, resize, rename
        case bulk(BulkTool)
        /// Name a new album; the photos go into it.
        case newAlbum([URL])
        case renameAlbum(Album.ID)
        case pages(PageSheet.Mode, [URL])
        case collage([URL])
        case duplicates([ScannedPhoto])

        var id: String {
            switch self {
            case .export: "export"
            case .resize: "resize"
            case .rename: "rename"
            case .bulk: "bulk"
            case .newAlbum: "newAlbum"
            case .renameAlbum: "renameAlbum"
            case .pages(let mode, _): "pages-\(mode.rawValue)"
            case .collage: "collage"
            case .duplicates: "duplicates"
            }
        }
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

    // MARK: Export and share

    private(set) var customPresets: [ExportPreset] = []

    /// Saved combinations of tone, color and looks.
    private(set) var editPresets: [EditPreset] = {
        guard let data = UserDefaults.standard.data(forKey: "edit.presets") else { return [] }
        return (try? JSONDecoder().decode([EditPreset].self, from: data)) ?? []
    }()

    func saveEditPreset(_ preset: EditPreset) {
        editPresets.append(preset)
        UserDefaults.standard.set(try? JSONEncoder().encode(editPresets), forKey: "edit.presets")
    }

    func deleteEditPreset(_ id: EditPreset.ID) {
        editPresets.removeAll { $0.id == id }
        UserDefaults.standard.set(try? JSONEncoder().encode(editPresets), forKey: "edit.presets")
    }

    /// Copies a logo into Fotolark's own storage so watermarks keep working if the
    /// original file moves.
    func importLogo(from url: URL) -> String? {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fotolark/Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        return (try? FileManager.default.copyItem(at: url, to: target)) != nil ? target.path : nil
    }
    var exportPresets: [ExportPreset] { ExportPreset.builtIn + customPresets }

    func saveExportPreset(_ preset: ExportPreset) {
        customPresets.append(preset)
        persistPresets()
    }

    func deleteExportPreset(_ id: ExportPreset.ID) {
        customPresets.removeAll { $0.id == id }
        persistPresets()
    }

    private func persistPresets() {
        UserDefaults.standard.set(try? JSONEncoder().encode(customPresets), forKey: "export.presets")
    }

    /// A photo's current edits: the open editor's, or what's saved.
    func recipe(for url: URL) -> EditRecipe {
        if let editor, editor.url == url { editor.commitPending(); return editor.history.current }
        return recipes[url] ?? store.load(for: url) ?? EditRecipe()
    }

    func exportOne(_ photo: URL, options: ExportOptions, to destination: URL) {
        let recipe = recipe(for: photo)
        let engine = engine
        jobs.run("Export \(photo.lastPathComponent)", items: [photo], outputFolder: destination,
                 name: { $0.lastPathComponent }) { url in
            try ImageExporter.export(source: url, recipe: recipe, options: options, to: destination, engine: engine)
            return [.removeCreatedFile(destination)]
        }
    }

    func exportMany(_ photos: [URL], options: ExportOptions, to folder: URL) {
        let recipes = Dictionary(uniqueKeysWithValues: photos.map { ($0, recipe(for: $0)) })
        let engine = engine
        jobs.run("Export \(photos.count) photos", items: photos, outputFolder: folder,
                 name: { $0.lastPathComponent }) { url in
            try BulkTools.exportCopy(of: url, recipe: recipes[url] ?? EditRecipe(), options: options,
                                     to: folder, engine: engine)
        }
    }

    /// Edited copies in a temporary folder, for the Share menu and dragging out.
    /// Unedited photos are shared as they are.
    nonisolated static func renderForSharing(_ photos: [URL], recipes: [URL: EditRecipe], engine: EditEngine) -> [URL] {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Fotolark Share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return photos.compactMap { url in
            guard let recipe = recipes[url], !recipe.isEmpty else { return url }
            return try? BulkTools.exportCopy(of: url, recipe: recipe, options: ExportOptions(format: .jpeg, quality: 0.92),
                                             to: folder, engine: engine)
                .compactMap { if case .removeCreatedFile(let u) = $0 { u } else { nil } }.first
        }
    }

    func sharingItems() async -> [URL] {
        let photos = targetPhotos
        let recipes = Dictionary(uniqueKeysWithValues: photos.map { ($0, recipe(for: $0)) })
        let engine = engine
        return await Task.detached(priority: .userInitiated) {
            Self.renderForSharing(photos, recipes: recipes, engine: engine)
        }.value
    }

    // MARK: Bulk tools

    /// Capture dates (falling back to the file's creation date) for renaming and sorting.
    func datesTaken(for urls: [URL]) -> [URL: Date] {
        let known = photos.filter { urls.contains($0.url) }
        var out = dates.dates(for: known)
        for url in urls where out[url] == nil {
            out[url] = PhotoMetadata.dateTaken(url) ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        }
        return out
    }

    func bulkConvert(_ photos: [URL], options: ExportOptions, includeEdits: Bool, to folder: URL?) {
        let recipes = Dictionary(uniqueKeysWithValues: photos.map { ($0, includeEdits ? recipe(for: $0) : EditRecipe()) })
        let engine = engine
        jobs.run("Convert \(photos.count) to \(options.format.displayName)", items: photos, outputFolder: folder,
                 name: { $0.lastPathComponent }) { url in
            try BulkTools.exportCopy(of: url, recipe: recipes[url] ?? EditRecipe(), options: options,
                                     to: folder ?? url.deletingLastPathComponent(), engine: engine)
        }
    }

    func bulkResize(_ photos: [URL], rule: BulkTools.ResizeRule, allowEnlarging: Bool, format: ExportFormat?,
                    quality: Double, includeEdits: Bool, to folder: URL?) {
        let recipes = Dictionary(uniqueKeysWithValues: photos.map { ($0, includeEdits ? recipe(for: $0) : EditRecipe()) })
        let engine = engine
        jobs.run("Resize \(photos.count) photos", items: photos, outputFolder: folder,
                 name: { $0.lastPathComponent }) { url in
            let options = ExportOptions(format: format ?? BulkTools.sameFormat(as: url), quality: quality)
            let out = folder ?? url.deletingLastPathComponent().appendingPathComponent("Resized", isDirectory: true)
            return try BulkTools.resizedCopy(of: url, recipe: recipes[url] ?? EditRecipe(), rule: rule,
                                             allowEnlarging: allowEnlarging, options: options, to: out, engine: engine)
        }
    }

    func bulkRename(_ items: [RenamePreviewItem]) {
        closeEditor()
        let store = store
        let count = items.filter { $0.problem == nil && !$0.isUnchanged }.count
        jobs.add("Rename \(count) photos", total: count) { _, progress in
            RenamePlan.apply(items, store: store, progress: progress)
        }
    }

    func bulkRotate(_ photos: [URL], turns: Int) {
        if let editor, photos == [editor.url] {
            for _ in 0..<abs(turns) { editor.rotate(clockwise: turns > 0) }
            return
        }
        let store = store
        jobs.run("Rotate \(photos.count) photos", items: photos, name: { $0.lastPathComponent }) { url in
            var steps: [UndoStep] = []
            for _ in 0..<abs(turns) { steps += try BulkTools.rotate(url, clockwise: turns > 0, store: store) }
            // Undo only needs the edits from before the first turn.
            return Array(steps.prefix(1))
        }
    }

    func bulkEditDetails(_ photos: [URL], changes: MetadataChanges, title: String = "Update details of") {
        let backups = backupDirectory
        jobs.run("\(title) \(photos.count == 1 ? photos[0].lastPathComponent : "\(photos.count) photos")",
                 items: photos, maxConcurrent: 2,
                 name: { $0.lastPathComponent }) { url in
            try MetadataEditor.apply(changes, to: url, backupDirectory: backups)
        }
    }

    func bulkApplyEdits(_ photos: [URL], edits: EditRecipe, title: String, addOnly: Bool) {
        if let editor, photos == [editor.url] {
            if addOnly { editor.toggleAutoFix(.magicFix) } else { editor.paste(edits) }
            return
        }
        let store = store
        let engine = engine
        jobs.run("\(title) on \(photos.count) photos", items: photos, name: { $0.lastPathComponent }) { url in
            try BulkTools.applyEdits(edits, to: url, store: store, engine: engine, addOnly: addOnly)
        }
    }

    func bulkTransfer(_ photos: [URL], copy: Bool, to folder: URL, dateFolders: DateFolderPattern?, dates: [URL: Date]) {
        if !copy { closeEditor() }
        let store = store
        jobs.run("\(copy ? "Copy" : "Move") \(photos.count) photos", items: photos, outputFolder: folder,
                 maxConcurrent: 1, name: { $0.lastPathComponent }) { url in
            try BulkTools.transfer(url, copy: copy, to: folder, dateFolders: dateFolders, dateTaken: dates[url], store: store)
        }
    }

    // MARK: Ratings, flags and tags

    /// Also write tag changes into the photo files (XMP keywords) for other apps.
    var writesTagsToFiles = UserDefaults.standard.bool(forKey: "writeTagsToFiles") {
        didSet { UserDefaults.standard.set(writesTagsToFiles, forKey: "writeTagsToFiles") }
    }

    /// Tags used before, offered while typing.
    private(set) var knownTags: [String] = UserDefaults.standard.stringArray(forKey: "knownTags") ?? []

    func labels(for url: URL) -> PhotoLabels { labels[url] ?? PhotoLabels() }

    private let labelQueue = DispatchQueue(label: "Fotolark labels", qos: .userInitiated)

    /// Rates, flags or tags photos (the one being edited, or the grid selection).
    func applyLabel(_ change: LabelChange, to urls: [URL]? = nil) {
        let targets = urls ?? targetPhotos
        guard !targets.isEmpty else { return }
        var changedTargets: [URL] = []
        for url in targets {
            var l = labels(for: url)
            let before = l
            change.apply(to: &l)
            guard l != before else { continue }
            labels[url] = l.isEmpty ? nil : l
            changedTargets.append(url)
        }
        guard !changedTargets.isEmpty else { return }
        for url in changedTargets { index.updateLabels(labels(for: url), for: url) }
        if filter.isActive { applyFilter() }
        if case .addTag(let tag) = change { remember(tag) }
        let store = store
        let snapshot = changedTargets.map { ($0, labels(for: $0)) }
        // One at a time, in order, so quick key presses can't land out of order.
        labelQueue.async { [weak self] in
            var failed = 0
            for (url, l) in snapshot where (try? store.update(url, change: { $0.labels = l })) == nil { failed += 1 }
            if failed > 0 {
                Task { @MainActor in self?.errorMessage = "Couldn’t save the change for \(failed) of the photos." }
            }
        }
        if writesTagsToFiles {
            var changes = MetadataChanges()
            switch change {
            case .addTag(let t): changes.addKeywords = [t]
            case .removeTag(let t): changes.removeKeywords = [t]
            default: return
            }
            bulkEditDetails(changedTargets, changes: changes, title: "Save tags into")
        }
    }

    private func remember(_ tag: String) {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !knownTags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        knownTags.append(t)
        knownTags.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        UserDefaults.standard.set(knownTags, forKey: "knownTags")
    }

    // MARK: Search and the library index

    /// What's typed in the search field.
    var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    private var sourceBeforeSearch: Source?
    private var searchTask: Task<Void, Never>?

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let text = searchText.trimmingCharacters(in: .whitespaces)
            if text.isEmpty {
                if case .search = source { source = sourceBeforeSearch }
                return
            }
            if case .search = source {} else { sourceBeforeSearch = source }
            closeEditor()
            source = .search(text)
        }
    }

    /// Read text in photos so search can find it (Settings).
    var readsTextInPhotos = UserDefaults.standard.object(forKey: "readTextInPhotos") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(readsTextInPhotos, forKey: "readTextInPhotos")
            readTextInBackground()
        }
    }

    /// Updates the index a moment from now (changes often come in bursts).
    func scheduleReindex(after delay: Duration) {
        reindexTask?.cancel()
        reindexTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            refreshIndex()
        }
    }

    private func refreshIndex() {
        indexTask?.cancel()
        textTask?.cancel()
        let roots = Array(library.resolvedURLs.values)
        let index = index
        let store = store
        if index.count == 0 { indexStatus = "Indexing photos…" }
        indexTask = Task {
            let changed = await Task.detached(priority: .utility) {
                index.refresh(roots: roots, store: store, isCancelled: { Task.isCancelled })
            }.value
            guard !Task.isCancelled else { return }
            indexStatus = nil
            if changed, source == .timeline || source?.isSearch == true { reloadPhotos() }
            readTextInBackground()
        }
    }

    /// Reads text in photos not read yet, a few at a time in the background.
    private func readTextInBackground() {
        textTask?.cancel()
        let index = index
        let analysis = analysis
        let context = engine.context
        let analyzes = analyzesPhotos
        textTask = Task {
            // First faces and look-alikes (quicker per photo), then text.
            if analyzes {
                let todo = analysis.needsAnalysis(index.all.map(\.scanned))
                for (i, photo) in todo.enumerated() {
                    if Task.isCancelled { return }
                    indexStatus = "Looking for faces and look-alikes: \((i + 1).formatted()) of \(todo.count.formatted())"
                    let result = await Task.detached(priority: .background) {
                        PhotoAnalyzer.analyze(photo.url, context: context)
                    }.value
                    analysis.set(result ?? PhotoAnalysis(fingerprint: nil, faces: []), for: photo)
                    if i % 100 == 99 { analysis.save(); recomputeFaceGroups() }
                }
                if !todo.isEmpty {
                    analysis.prune(keeping: Set(index.all.map(\.path)))
                    analysis.save()
                }
                recomputeFaceGroups()
                indexStatus = nil
            }
            guard readsTextInPhotos else { return }
            let todo = index.photosNeedingText()
            guard !todo.isEmpty else { return }
            for (i, url) in todo.enumerated() {
                if Task.isCancelled { break }
                indexStatus = "Reading text in photos: \((i + 1).formatted()) of \(todo.count.formatted())"
                let text = await Task.detached(priority: .background) { LibraryIndex.recognizeText(in: url) }.value
                index.setText(text, for: url)
                if i % 50 == 49 { index.save() }
            }
            index.save()
            if !Task.isCancelled { indexStatus = nil }
        }
    }

    // MARK: People and duplicates

    /// Look for faces and similar photos in the background (Settings).
    var analyzesPhotos = UserDefaults.standard.object(forKey: "analyzePhotos") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(analyzesPhotos, forKey: "analyzePhotos")
            readTextInBackground()
        }
    }

    /// How alike faces must be to be grouped together (People view).
    var faceThreshold = UserDefaults.standard.object(forKey: "faceThreshold") as? Double
        ?? Double(PeopleStore.sameFaceThreshold) {
        didSet {
            UserDefaults.standard.set(faceThreshold, forKey: "faceThreshold")
            recomputeFaceGroups()
        }
    }

    var people: [Person] { faceGroups.compactMap(\.person) }

    private var faceTask: Task<Void, Never>?

    func recomputeFaceGroups() {
        faceTask?.cancel()
        let photos = index.all.map(\.scanned)
        let analysis = analysis, store = peopleStore, threshold = Float(faceThreshold)
        faceTask = Task {
            let groups = await Task.detached(priority: .utility) {
                store.groups(analysis.allFaces(in: photos), threshold: threshold)
            }.value
            guard !Task.isCancelled else { return }
            faceGroups = groups
            switch source {
            case .person, .faceGroup: reloadPhotos()
            default: break
            }
        }
    }

    private func photosForFaces(_ source: Source) -> [URL] {
        let group: FaceGroup?
        switch source {
        case .person(let id): group = faceGroups.first { $0.person?.id == id }
        case .faceGroup(let id): group = faceGroups.first { $0.id == id }
        default: return []
        }
        var seen = Set<URL>()
        return (group?.faces ?? []).map(\.photo).filter { seen.insert($0).inserted }
    }

    var currentFaceGroup: FaceGroup? {
        switch source {
        case .person(let id): faceGroups.first { $0.person?.id == id }
        case .faceGroup(let id): faceGroups.first { $0.id == id }
        default: nil
        }
    }

    func nameFaces(_ group: FaceGroup, as name: String) {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let person = peopleStore.name(group.faces.map(\.face.id), as: name)
        if case .faceGroup(group.id) = source { source = .person(person.id) }
        recomputeFaceGroups()
    }

    func renamePerson(_ id: Person.ID, to name: String) {
        peopleStore.rename(id, to: name)
        recomputeFaceGroups()
    }

    func forgetPerson(_ id: Person.ID) {
        peopleStore.delete(id)
        if source == .person(id) { source = .people }
        recomputeFaceGroups()
    }

    /// "Not this person": takes the selected photos' faces out of the group shown.
    func removeFromFaceGroup() {
        guard let group = currentFaceGroup else { return }
        let targets = Set(targetPhotos)
        for item in group.faces where targets.contains(item.photo) { peopleStore.remove(item.face.id) }
        recomputeFaceGroups()
    }

    func showDuplicates() {
        let scope = selection.count > 1 ? photos.filter { selection.contains($0.url) } : photos
        guard scope.count > 1 else { return }
        sheet = .duplicates(scope)
    }

    /// Moves photos to the Trash (from the duplicates sheet).
    func trash(_ urls: [URL]) {
        closeEditor()
        var failed: [String] = []
        for url in urls {
            do { try fileOperations.moveToTrash(url) } catch { failed.append(url.lastPathComponent) }
        }
        reloadPhotos()
        if !failed.isEmpty { errorMessage = "Couldn’t move \(failed.joined(separator: ", ")) to the Trash." }
    }

    // MARK: Albums

    var currentAlbum: Album? {
        guard case .album(let id) = source else { return nil }
        return albums.first { $0.id == id }
    }

    func createAlbum(named name: String, with photos: [URL]) {
        let album = albumStore.create(named: name, with: photos)
        albums = albumStore.albums
        if photos.isEmpty { closeEditor(); source = .album(album.id) }
    }

    func addToAlbum(_ id: Album.ID, photos: [URL]? = nil) {
        albumStore.add(photos ?? targetPhotos, to: id)
        albums = albumStore.albums
    }

    func removeFromCurrentAlbum() {
        guard let album = currentAlbum else { return }
        let targets = targetPhotos
        closeEditor()
        albumStore.remove(targets, from: album.id)
        albums = albumStore.albums
        reloadPhotos()
    }

    func renameAlbum(_ id: Album.ID, to name: String) {
        albumStore.rename(id, to: name)
        albums = albumStore.albums
    }

    func deleteAlbum(_ id: Album.ID) {
        albumStore.delete(id)
        albums = albumStore.albums
        if case .album(id) = source { source = nil }
    }

    // MARK: Print, contact sheets, collages and PDFs

    /// The selected photos, or every photo shown when none are selected.
    var layoutPhotos: [URL] {
        let targets = targetPhotos
        return targets.isEmpty ? photos.map(\.url) : targets
    }

    func showPages(_ mode: PageSheet.Mode) {
        let list = layoutPhotos
        guard !list.isEmpty else { return }
        sheet = .pages(mode, list)
    }

    func showCollage() {
        let list = layoutPhotos
        guard !list.isEmpty else { return }
        sheet = .collage(Array(list.prefix(60)))
    }

    /// The folder, album or search shown, for names of PDFs and collages.
    var sourceTitle: String {
        switch source {
        case .folder(let url): url.lastPathComponent
        case .album: currentAlbum?.name ?? "Album"
        case .timeline: "All Photos"
        case .search(let text): text
        default: editor?.url.deletingPathExtension().lastPathComponent ?? "Photos"
        }
    }

    // MARK: Remove background

    /// Saves each photo's subject (with its edits) as a PNG with a see-through background.
    func removeBackground() {
        let targets = targetPhotos
        guard !targets.isEmpty else { return }
        let recipes = Dictionary(uniqueKeysWithValues: targets.map { ($0, recipe(for: $0)) })
        let engine = engine
        if targets.count == 1 {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = targets[0].deletingPathExtension().lastPathComponent + " cutout.png"
            panel.message = "Save the subject on a see-through background"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let photo = targets[0]
            jobs.run("Remove background from \(photo.lastPathComponent)", items: [photo],
                     outputFolder: url.deletingLastPathComponent(), name: { $0.lastPathComponent }) { photo in
                let png = try engine.cutout(source: photo, recipe: recipes[photo] ?? EditRecipe())
                try png.write(to: url, options: .atomic)
                return [.removeCreatedFile(url)]
            }
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose where to save \(targets.count) cutouts (PNG, see-through background)."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            jobs.run("Remove background from \(targets.count) photos", items: targets, outputFolder: folder,
                     name: { $0.lastPathComponent }) { photo in
                let png = try engine.cutout(source: photo, recipe: recipes[photo] ?? EditRecipe())
                let target = PhotoFileOperations.availableURL(
                    for: photo.deletingPathExtension().lastPathComponent + " cutout.png", in: folder)
                try png.write(to: target, options: .withoutOverwriting)
                return [.removeCreatedFile(target)]
            }
        }
    }

    // MARK: Slideshow

    var canStartSlideshow: Bool { !photos.isEmpty && comparing == nil }

    /// Plays the selected photos (if several are selected) or all of them, starting
    /// from the photo being edited or selected.
    func startSlideshow() {
        guard canStartSlideshow else { return }
        let urls = selection.count > 1 && editor == nil
            ? photos.map(\.url).filter { selection.contains($0) }
            : photos.map(\.url)
        let current = editor?.url ?? (selection.count == 1 ? selection.first : nil)
        let start = current.flatMap { urls.firstIndex(of: $0) } ?? 0
        var recipes = self.recipes
        if let editor { editor.commitPending(); recipes[editor.url] = editor.history.current }
        SlideshowWindow.show(urls: urls, start: start, recipes: recipes, engine: engine)
    }

    // MARK: Compare

    /// Photos shown side by side, or nil when not comparing.
    private(set) var comparing: [URL]?

    var canCompare: Bool { editor == nil && (2...4).contains(targetPhotos.count) }

    func compareSelection() {
        guard canCompare else { return }
        comparing = targetPhotos
    }

    func endCompare() {
        if let first = comparing?.first { selection = Set(comparing ?? [first]) }
        comparing = nil
    }

    // MARK: Import

    static func importKey(_ source: any ImportSource) -> String {
        if let folder = source as? FolderImportSource { return "folder:" + folder.folder.path }
        if source is PhotosLibrarySource { return "photos" }
        return "device:\(ObjectIdentifier(source).hashValue)"
    }

    var allImportSources: [any ImportSource] {
        (devices.devices as [any ImportSource]) + (folderImports as [any ImportSource])
            + (photosLibrary.map { [$0 as any ImportSource] } ?? [])
    }

    // MARK: Apple Photos

    /// Made when first opened, so Fotolark asks for Photos access only when it's wanted.
    private(set) var photosLibrary: PhotosLibrarySource?
    /// The Photos picture being edited, if the editor is working on one.
    private(set) var photosSession: PhotosEditSession?
    private(set) var isSavingToPhotos = false

    func showPhotosLibrary() {
        if photosLibrary == nil { photosLibrary = PhotosLibrarySource() }
        closeEditor()
        source = .importing("photos")
    }

    /// Opens a picture from Photos in the editor (working on a copy).
    func editFromPhotos(_ id: String) {
        guard let asset = photosLibrary?.asset(id) else { return }
        guard asset.mediaType == .image else {
            errorMessage = "Only photos can be edited, not videos."
            return
        }
        Task {
            do {
                let session = try await PhotosEditSession.begin(asset, store: store)
                photosSession = session
                open([session.workingURL])
            } catch {
                errorMessage = "Couldn’t open that picture from Photos: \(error.localizedDescription)"
            }
        }
    }

    var isEditingPhotosPicture: Bool {
        guard let editor, let photosSession else { return false }
        return editor.url.standardizedFileURL == photosSession.workingURL.standardizedFileURL
    }

    /// Saves the edited picture back into Photos as an edit (Photos keeps the original).
    func saveToPhotos() {
        guard isEditingPhotosPicture, let editor, let session = photosSession else { return }
        editor.saveNow()
        let recipe = editor.history.current
        isSavingToPhotos = true
        Task {
            do {
                try await session.save(recipe, engine: engine)
                isSavingToPhotos = false
                editor.toolMessage = "Saved to Photos. Photos keeps the original; choose Revert to Original there to undo."
            } catch {
                isSavingToPhotos = false
                errorMessage = "Couldn’t save to Photos: \(error.localizedDescription)"
            }
        }
    }

    func importSource(for key: String) -> (any ImportSource)? {
        allImportSources.first { Self.importKey($0) == key }
    }

    func importFromFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Import From Here"
        panel.message = "Choose a memory card, drive or folder to import photos from. Subfolders are included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let source = folderImports.first { $0.folder == url } ?? FolderImportSource(folder: url, thumbnails: thumbnails)
        if !folderImports.contains(where: { $0 === source }) { folderImports.append(source) }
        closeEditor()
        self.source = .importing(Self.importKey(source))
    }

    func removeFolderImport(_ source: FolderImportSource) {
        folderImports.removeAll { $0 === source }
        if case .importing(let key) = self.source, key == Self.importKey(source) { self.source = nil }
    }

    /// Copies photos from a device into `root`, checking each copy, and optionally
    /// deleting the checked ones from the device afterwards.
    func runImport(_ items: [ImportCandidate], from source: any ImportSource, options: ImportOptions, to root: URL,
                   deleteAfter: Bool) {
        let engine = engine
        let history = importHistory
        jobs.runOnMain("Import \(items.count) from \(source.title)", total: items.count, outputFolder: root) { control, progress in
            var result = BulkResult()
            var verified: [ImportCandidate.ID] = []
            var imported = 0
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("Fotolark Import", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }

            for (i, c) in items.enumerated() {
                guard await control.waitIfPaused() else { break }
                defer { result.completed = i + 1; progress(i + 1) }
                if options.skipDuplicates,
                   Importer.isDuplicate(c, index: imported, options: options, root: root, history: history) {
                    result.skipped.append(SkippedItem(name: c.name, reason: "Already imported"))
                    continue
                }
                do {
                    let downloaded = try await source.download(c.id, to: temp)
                    let index = imported
                    let placed = try await Task.detached(priority: .userInitiated) {
                        try Importer.place(downloaded, candidate: c, index: index, options: options, root: root, engine: engine)
                    }.value
                    imported += 1
                    result.undo += placed.undo
                    history.insert(c)
                    if placed.verified {
                        verified.append(c.id)
                    } else if deleteAfter {
                        result.skipped.append(SkippedItem(name: c.name, reason: "The copy couldn’t be checked, so it was left on \(source.title)"))
                    }
                } catch {
                    result.skipped.append(SkippedItem(name: c.name, reason: error.localizedDescription))
                }
            }
            history.save()
            result.wasCancelled = control.isCancelled && result.completed < items.count

            if deleteAfter && !verified.isEmpty && !control.isCancelled {
                for name in await source.delete(verified) {
                    result.skipped.append(SkippedItem(name: name, reason: "Couldn’t delete it from \(source.title)"))
                }
            }
            self.library.add(root)
            self.library.rescanAll()
            return result
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

extension AppModel.Source {
    /// True for sources shown in the photo grid.
    var isBrowsable: Bool {
        switch self {
        case .importing, .people: false
        default: true
        }
    }

    /// Folders, albums and opened photos follow the sort menu; the timeline and search
    /// results are always newest first.
    var isFolderLike: Bool {
        switch self {
        case .timeline, .search, .person, .faceGroup: false
        default: true
        }
    }

    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }
}

/// A titled group of photos in the grid (a month in the timeline).
struct GridSection: Equatable {
    let id: String
    let title: String
    var urls: [URL]
}

/// Which photos the grid shows.
struct GridFilter: Equatable {
    enum FlagFilter: String, CaseIterable, Identifiable {
        case any, picks, hideRejects, rejects
        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: "Any"
            case .picks: "Picks Only"
            case .hideRejects: "Hide Rejects"
            case .rejects: "Rejects Only"
            }
        }
    }

    /// At least this many stars (0 = any).
    var minRating = 0
    var flag = FlagFilter.any
    /// Only photos with this tag.
    var tag: String?

    var isActive: Bool { minRating > 0 || flag != .any || tag != nil }

    func matches(_ labels: PhotoLabels?) -> Bool {
        let l = labels ?? PhotoLabels()
        if l.rating < minRating { return false }
        switch flag {
        case .any: break
        case .picks: if l.flag != .pick { return false }
        case .hideRejects: if l.flag == .reject { return false }
        case .rejects: if l.flag != .reject { return false }
        }
        if let tag, !l.hasTag(tag) { return false }
        return true
    }

    var summary: String {
        var parts: [String] = []
        if minRating > 0 { parts.append(String(repeating: "★", count: minRating) + (minRating < 5 ? " or more" : "")) }
        if flag != .any { parts.append(flag.title.lowercased()) }
        if let tag { parts.append("tagged “\(tag)”") }
        return parts.joined(separator: ", ")
    }
}

extension ImportSource {
    var importKey: String { AppModel.importKey(self) }
}

extension LabelChange {
    /// The key that makes this change in the grid or editor: 0–5 rate, P picks,
    /// X rejects, U clears the flag.
    init?(key: String) {
        switch key.lowercased() {
        case "0", "1", "2", "3", "4", "5": self = .rating(Int(key)!)
        case "p": self = .flag(.pick)
        case "x": self = .flag(.reject)
        case "u": self = .flag(.none)
        default: return nil
        }
    }
}
