import Foundation

/// One-step jobs for Shortcuts, Finder and watch folders: resize, convert and auto-fix
/// a photo into a new file. The original is never changed.
public enum QuickActions {
    public enum Action: Codable, Equatable, Sendable {
        /// Longest side at most this many pixels (never enlarged).
        case resize(longestSide: Int)
        case convert(ExportFormat)
        /// Magic fix, worked out for each photo.
        case autoFix
    }

    /// The finished file's data and suggested name.
    public static func run(_ action: Action, on photo: URL, format: ExportFormat? = nil, quality: Double = 0.9,
                           engine: EditEngine) throws -> (data: Data, name: String) {
        var recipe = EditRecipe()
        var options = ExportOptions(format: format ?? BulkTools.sameFormat(as: photo), quality: quality)
        switch action {
        case .resize(let side):
            options.maxLongestSide = max(16, side)
        case .convert(let f):
            options.format = f
        case .autoFix:
            let preview = try ImageLoader.loadPreview(photo, maxPixelSize: 1024)
            recipe = recipe.setting(engine.magicFix(for: preview))
        }
        let data = try ImageExporter.encode(source: photo, recipe: recipe, options: options, engine: engine)
        let base = photo.deletingPathExtension().lastPathComponent
        let suffix: String
        switch action {
        case .resize(let side): suffix = " \(side)px"
        case .convert: suffix = ""
        case .autoFix: suffix = " fixed"
        }
        return (data, base + suffix + "." + options.format.fileExtension)
    }
}

/// A folder Fotolark keeps an eye on: photos dropped into it are converted or resized
/// into a subfolder automatically. Originals stay where they are.
public struct WatchFolderRule: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Last known path (shown if the folder can't be reached).
    public var path: String
    public var bookmark: Data?
    public var action: QuickActions.Action
    /// Format of the results; nil keeps each photo's own.
    public var format: ExportFormat?
    public var quality = 0.9
    /// Name of the subfolder the results go in.
    public var outputFolderName = "Fotolark"
    public var isEnabled = true

    public init(path: String, bookmark: Data?, action: QuickActions.Action, format: ExportFormat? = nil) {
        self.path = path
        self.bookmark = bookmark
        self.action = action
        self.format = format
    }

    public var summary: String {
        switch action {
        case .resize(let side): "Resize to \(side) px" + (format.map { " \($0.displayName)" } ?? "")
        case .convert(let f): "Convert to \(f.displayName)"
        case .autoFix: "Magic fix" + (format.map { " as \($0.displayName)" } ?? "")
        }
    }
}

public enum WatchFolderProcessor {
    /// Photos directly in `folder` that haven't been handled yet. A file still being
    /// copied in (its size changed since `sizes` was taken) waits for the next look.
    public static func pending(in folder: URL, handled: Set<String>, previousSizes: [String: Int64]) -> [ScannedPhoto] {
        PhotoScanner.photos(in: folder).filter { p in
            let key = handledKey(p)
            guard !handled.contains(key) else { return false }
            return previousSizes[p.url.lastPathComponent] == p.fileSize
        }
    }

    /// Identifies a file by name, size and date, so a replaced file is handled again.
    public static func handledKey(_ p: ScannedPhoto) -> String {
        "\(p.name)|\(p.fileSize)|\(Int(p.modified.timeIntervalSince1970))"
    }

    /// Makes the result in the rule's subfolder and returns it.
    @discardableResult
    public static func process(_ photo: URL, rule: WatchFolderRule, in folder: URL, engine: EditEngine) throws -> URL {
        let out = folder.appendingPathComponent(rule.outputFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try QuickActions.run(rule.action, on: photo, format: rule.format, quality: rule.quality, engine: engine)
        let target = PhotoFileOperations.availableURL(for: result.name, in: out)
        try result.data.write(to: target, options: .withoutOverwriting)
        return target
    }
}
