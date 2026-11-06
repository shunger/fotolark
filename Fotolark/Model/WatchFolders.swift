import AppKit
import FotolarkKit
import Observation

/// Folders where photos dropped in are converted or resized automatically, while
/// Fotolark is open. Results go in a subfolder; originals are left alone.
@MainActor @Observable
final class WatchFolders {
    private(set) var rules: [WatchFolderRule] = []
    /// What happened last, per rule (shown in Settings).
    private(set) var status: [WatchFolderRule.ID: String] = [:]

    private let saveURL: URL
    private let engine: EditEngine
    private var resolved: [WatchFolderRule.ID: URL] = [:]
    private var handled: [WatchFolderRule.ID: Set<String>] = [:]
    private var sizes: [WatchFolderRule.ID: [String: Int64]] = [:]
    private var watcher: FolderWatcher?
    private var checkTask: Task<Void, Never>?
    private var isWorking = false

    struct Saved: Codable {
        var rules: [WatchFolderRule]
        var handled: [UUID: Set<String>]
    }

    init(supportDirectory: URL, engine: EditEngine) {
        saveURL = supportDirectory.appendingPathComponent("WatchFolders.json")
        self.engine = engine
        if let data = try? Data(contentsOf: saveURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            rules = saved.rules
            handled = saved.handled
        }
        for rule in rules { resolve(rule) }
        restart()
        scheduleCheck(after: .seconds(2))
    }

    /// Asks for a folder and starts watching it. Photos already in it are left alone.
    func addWithPanel(action: QuickActions.Action, format: ExportFormat?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Watch This Folder"
        panel.message = "Photos you drop into this folder will be processed into a “Fotolark” folder inside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let rule = WatchFolderRule(path: url.path, bookmark: bookmark, action: action, format: format)
        rules.append(rule)
        resolved[rule.id] = url
        handled[rule.id] = Set(PhotoScanner.photos(in: url).map(WatchFolderProcessor.handledKey))
        status[rule.id] = "Watching. Drop photos in to process them."
        persist()
        restart()
    }

    func remove(_ id: WatchFolderRule.ID) {
        resolved[id]?.stopAccessingSecurityScopedResource()
        rules.removeAll { $0.id == id }
        resolved[id] = nil
        handled[id] = nil
        persist()
        restart()
    }

    func setEnabled(_ id: WatchFolderRule.ID, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].isEnabled = on
        persist()
        restart()
        if on { scheduleCheck(after: .seconds(1)) }
    }

    func folderName(_ rule: WatchFolderRule) -> String { (rule.path as NSString).lastPathComponent }
    func isAvailable(_ rule: WatchFolderRule) -> Bool { resolved[rule.id] != nil }

    // MARK: Watching

    private func resolve(_ rule: WatchFolderRule) {
        var stale = false
        guard let data = rule.bookmark,
              let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return }
        resolved[rule.id] = url
    }

    private func restart() {
        watcher = nil
        let urls = rules.filter(\.isEnabled).compactMap { resolved[$0.id] }
        guard !urls.isEmpty else { return }
        watcher = FolderWatcher(urls: urls) { [weak self] _ in self?.scheduleCheck(after: .seconds(1)) }
    }

    /// Looks again a moment later, and once more after that, so a file still being
    /// copied in is processed once its size stops changing.
    private func scheduleCheck(after delay: Duration) {
        checkTask?.cancel()
        checkTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await check()
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await check()
        }
    }

    private func check() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        for rule in rules where rule.isEnabled {
            guard let folder = resolved[rule.id] else { continue }
            let done = handled[rule.id] ?? []
            let before = sizes[rule.id] ?? [:]
            let engine = engine
            let (ready, now) = await Task.detached(priority: .utility) {
                (WatchFolderProcessor.pending(in: folder, handled: done, previousSizes: before),
                 Dictionary(PhotoScanner.photos(in: folder).map { ($0.name, $0.fileSize) }, uniquingKeysWith: { a, _ in a }))
            }.value
            sizes[rule.id] = now
            guard !ready.isEmpty else { continue }
            var made = 0
            var failed: [String] = []
            for photo in ready {
                do {
                    try await Task.detached(priority: .utility) {
                        try WatchFolderProcessor.process(photo.url, rule: rule, in: folder, engine: engine)
                    }.value
                    made += 1
                } catch {
                    failed.append(photo.name)
                }
                handled[rule.id, default: []].insert(WatchFolderProcessor.handledKey(photo))
            }
            let time = Date().formatted(date: .omitted, time: .shortened)
            status[rule.id] = failed.isEmpty
                ? "\(time): processed \(made) \(made == 1 ? "photo" : "photos")."
                : "\(time): processed \(made); couldn’t process \(failed.joined(separator: ", "))."
            persist()
        }
    }

    private func persist() {
        try? FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Saved(rules: rules, handled: handled)).write(to: saveURL, options: .atomic)
    }
}
