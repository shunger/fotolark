import AppKit
import FotolarkKit
import Observation
import UniformTypeIdentifiers

/// The photos the person has opened, and which one is being edited.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var photos: [URL] = []
    private(set) var index: Int?
    private(set) var editor: PhotoEditor?
    var errorMessage: String?

    let engine = EditEngine()
    let store: RecipeStore
    let backupDirectory: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fotolark", isDirectory: true)
        store = RecipeStore(fallbackDirectory: support.appendingPathComponent("Recipes", isDirectory: true))
        backupDirectory = support.appendingPathComponent("Backups", isDirectory: true)
    }

    // MARK: Opening

    /// Opens photos and folders (a folder adds the photos directly inside it).
    func open(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                found += contents.filter(ImageLoader.canOpen)
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if ImageLoader.canOpen(url) {
                found.append(url)
            }
        }
        guard let first = found.first else {
            if !urls.isEmpty { errorMessage = "Fotolark couldn’t find any photos it can open there." }
            return
        }
        let known = Set(photos.map(\.standardizedFileURL))
        photos += found.filter { !known.contains($0.standardizedFileURL) }
        select(photos.firstIndex { $0.standardizedFileURL == first.standardizedFileURL } ?? 0)
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ImageLoader.readableTypes
        panel.message = "Choose photos, or a folder of photos"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    // MARK: Moving between photos

    func select(_ newIndex: Int) {
        guard photos.indices.contains(newIndex) else { return }
        if newIndex == index, editor != nil { return }
        editor?.saveNow()
        index = newIndex
        zoomScale = nil
        let url = photos[newIndex]
        do {
            editor = try PhotoEditor(url: url, engine: engine, store: store)
        } catch {
            editor = nil
            errorMessage = error.localizedDescription
        }
    }

    var canGoNext: Bool { index.map { $0 < photos.count - 1 } ?? false }
    var canGoPrevious: Bool { index.map { $0 > 0 } ?? false }

    func next() { if canGoNext, let i = index { select(i + 1) } }
    func previous() { if canGoPrevious, let i = index { select(i - 1) } }

    /// Opens the photo again from disk, e.g. after saving over it.
    func reloadCurrent() {
        guard let i = index else { return }
        editor = nil
        select(i)
    }

    // MARK: Window state

    enum Sheet: String, Identifiable {
        case export, resize
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
