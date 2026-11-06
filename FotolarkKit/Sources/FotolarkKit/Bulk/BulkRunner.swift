import Foundation

/// One thing to reverse when a bulk job is undone.
public enum UndoStep: Equatable, Sendable {
    /// A file the job created; undo moves it to the Trash.
    case removeCreatedFile(URL)
    /// A file the job moved or renamed from `original` to `current`; undo moves it back.
    case moveBack(current: URL, original: URL)
    /// A photo's edits before the job changed them (nil = no edits).
    case restoreRecipe(URL, EditRecipe?)
}

/// A photo the job left out, and why.
public struct SkippedItem: Equatable, Sendable, Identifiable {
    public let id = UUID()
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }

    public static func == (a: SkippedItem, b: SkippedItem) -> Bool { a.name == b.name && a.reason == b.reason }
}

/// Pause, resume and cancel for a running job. Safe to use from any thread.
public final class JobControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _paused = false
    private var _cancelled = false

    public init() {}

    public var isPaused: Bool {
        get { lock.withLock { _paused } }
        set { lock.withLock { _paused = newValue } }
    }

    public var isCancelled: Bool { lock.withLock { _cancelled } }

    public func cancel() { lock.withLock { _cancelled = true } }

    /// Waits while paused. Returns false once cancelled.
    func waitIfPaused() async -> Bool {
        while isPaused && !isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
        }
        return !isCancelled
    }
}

public struct BulkResult: Sendable {
    public var undo: [UndoStep] = []
    public var skipped: [SkippedItem] = []
    public var completed = 0
    public var wasCancelled = false
}

public enum BulkRunner {
    /// Runs `work` for every item, up to `maxConcurrent` at a time. An item that throws is
    /// skipped (with the error as the reason) and the rest carry on.
    public static func run<Item: Sendable>(
        _ items: [Item],
        name: @escaping @Sendable (Item) -> String,
        maxConcurrent: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 1),
        control: JobControl,
        progress: @escaping @Sendable (Int) -> Void,
        work: @escaping @Sendable (Item) throws -> [UndoStep]
    ) async -> BulkResult {
        var result = BulkResult()
        var next = 0
        await withTaskGroup(of: (Int, Result<[UndoStep], Error>).self) { group in
            var running = 0
            while true {
                // Keep up to maxConcurrent items going, unless paused or cancelled.
                while running < max(1, maxConcurrent), next < items.count, await control.waitIfPaused() {
                    let index = next
                    let item = items[index]
                    next += 1
                    running += 1
                    group.addTask { (index, Result { try work(item) }) }
                }
                guard let (index, outcome) = await group.next() else { break }
                running -= 1
                switch outcome {
                case .success(let steps): result.undo += steps
                case .failure(let error):
                    result.skipped.append(SkippedItem(name: name(items[index]), reason: error.localizedDescription))
                }
                result.completed += 1
                progress(result.completed)
            }
        }
        result.wasCancelled = control.isCancelled && result.completed < items.count
        return result
    }

    /// Reverses a job. Returns anything that couldn't be put back.
    ///
    /// Moved and renamed files go back in two steps (to temporary names, then their
    /// original names), so a rename that swapped two names can be undone too.
    public static func undo(_ steps: [UndoStep], store: RecipeStore) -> [SkippedItem] {
        var problems: [SkippedItem] = []
        let ops = PhotoFileOperations(store: store)
        func fail(_ url: URL, _ error: Error) {
            problems.append(SkippedItem(name: url.lastPathComponent, reason: error.localizedDescription))
        }

        for step in steps.reversed() {
            switch step {
            case .removeCreatedFile(let url):
                do {
                    if FileManager.default.fileExists(atPath: url.path) { try ops.moveToTrash(url) }
                } catch { fail(url, error) }
            case .restoreRecipe(let url, let recipe):
                do { try store.save(recipe ?? EditRecipe(), for: url) } catch { fail(url, error) }
            case .moveBack:
                break
            }
        }

        var staged: [(temp: URL, original: URL, current: URL, recipe: EditRecipe?)] = []
        for case let .moveBack(current, original) in steps.reversed() {
            let temp = current.deletingLastPathComponent().appendingPathComponent(".fotolark-undo-\(UUID().uuidString)")
            do {
                let recipe = store.load(for: current)
                try FileManager.default.moveItem(at: current, to: temp)
                if recipe != nil { _ = try? store.save(EditRecipe(), for: current) }
                staged.append((temp, original, current, recipe))
            } catch { fail(current, error) }
        }
        for item in staged {
            do {
                guard !FileManager.default.fileExists(atPath: item.original.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try FileManager.default.createDirectory(at: item.original.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.temp, to: item.original)
                if let r = item.recipe { _ = try? store.save(r, for: item.original) }
            } catch {
                // Leave it where the job had put it.
                try? FileManager.default.moveItem(at: item.temp, to: item.current)
                if let r = item.recipe { _ = try? store.save(r, for: item.current) }
                fail(item.current, error)
            }
        }
        return problems
    }
}
