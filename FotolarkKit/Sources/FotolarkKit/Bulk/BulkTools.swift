import Foundation

/// Work done per photo by bulk jobs. Each function handles one photo and returns the
/// steps that undo it; `BulkRunner` runs them across many photos.
public enum BulkTools {
    // MARK: Export, convert and resize

    /// Writes an edited copy of `photo` into `folder`, never replacing an existing file.
    public static func exportCopy(of photo: URL, recipe: EditRecipe, options: ExportOptions, to folder: URL,
                                  suffix: String = "", engine: EditEngine) throws -> [UndoStep] {
        let data = try ImageExporter.encode(source: photo, recipe: recipe, options: options, engine: engine)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = ImageExporter.fileName(for: photo, format: options.format, suffix: suffix)
        // Several copies may be written into one folder at once, so never overwrite:
        // if another job took the name in the meantime, try the next free one.
        for _ in 0..<50 {
            let target = PhotoFileOperations.availableURL(for: name, in: folder)
            do {
                try data.write(to: target, options: .withoutOverwriting)
                return [.removeCreatedFile(target)]
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// How a bulk resize picks the new size.
    public enum ResizeRule: Equatable, Sendable {
        /// Longest side in pixels.
        case longestSide(Int)
        /// Percent of the current size.
        case percent(Double)
    }

    /// Resized copy of `photo` (with its edits) in `folder`. Photos already small enough
    /// are copied at their size unless `allowEnlarging`.
    public static func resizedCopy(of photo: URL, recipe: EditRecipe, rule: ResizeRule, allowEnlarging: Bool,
                                   options: ExportOptions, to folder: URL, engine: EditEngine) throws -> [UndoStep] {
        let size = Geometry.outputSize(of: recipe.removing(.resize), source: try ImageLoader.info(for: photo).pixelSize)
        let longest = Double(max(size.width, size.height))
        let target: Double
        switch rule {
        case .longestSide(let px): target = Double(px)
        case .percent(let pct): target = longest * pct / 100
        }
        var r = recipe.removing(.resize)
        if target < longest || allowEnlarging {
            let s = target / longest
            r = r.setting(.resize(ResizeSpec(width: max(1, Int((Double(size.width) * s).rounded())),
                                             height: max(1, Int((Double(size.height) * s).rounded())))))
        }
        var o = options
        o.maxLongestSide = nil
        return try exportCopy(of: photo, recipe: r, options: o, to: folder, engine: engine)
    }

    /// The format a converted or resized copy keeps when "same as original" is chosen:
    /// the original's own format if Fotolark can write it, otherwise JPEG.
    public static func sameFormat(as photo: URL) -> ExportFormat {
        ExportFormat(typeIdentifier: (try? ImageLoader.info(for: photo))?.typeIdentifier) ?? .jpeg
    }

    // MARK: Rotate

    /// Turns a photo by changing its edits (the file itself isn't rewritten).
    public static func rotate(_ photo: URL, clockwise: Bool, store: RecipeStore) throws -> [UndoStep] {
        let old = store.load(for: photo)
        try store.save((old ?? EditRecipe()).rotated(clockwise: clockwise), for: photo)
        return [.restoreRecipe(photo, old)]
    }

    // MARK: Move and copy

    /// Moves or copies a photo into `folder`, optionally inside date-named subfolders.
    public static func transfer(_ photo: URL, copy: Bool, to folder: URL, dateFolders: DateFolderPattern?,
                                dateTaken: Date?, store: RecipeStore) throws -> [UndoStep] {
        var destination = folder
        if let dateFolders {
            let date = dateTaken ?? (try? photo.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            destination = dateFolders.folder(for: date, in: folder)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let ops = PhotoFileOperations(store: store)
        if copy {
            let made = try ops.copy([photo], to: destination)[0]
            return [.removeCreatedFile(made), .restoreRecipe(made, nil)]
        } else {
            guard destination.standardizedFileURL != photo.deletingLastPathComponent().standardizedFileURL else { return [] }
            let moved = try ops.move([photo], to: destination)[0]
            return [.moveBack(current: moved, original: photo)]
        }
    }
}

/// Folder names made from a photo's date, such as "2026/2026-11-06 Beach".
public struct DateFolderPattern: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        /// 2026/2026-11-06
        case yearThenDay
        /// 2026/2026-11
        case yearThenMonth
        /// 2026-11-06
        case day

        public var id: String { rawValue }

        public var example: String {
            switch self {
            case .yearThenDay: "2026 › 2026-11-06"
            case .yearThenMonth: "2026 › 2026-11"
            case .day: "2026-11-06"
            }
        }
    }

    public var style: Style
    /// Added after the date on the last folder, e.g. "Beach".
    public var eventName: String

    public init(style: Style = .yearThenDay, eventName: String = "") {
        self.style = style
        self.eventName = eventName
    }

    public func folder(for date: Date, in root: URL) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        func s(_ format: String) -> String { f.dateFormat = format; return f.string(from: date) }
        let event = eventName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let suffix = event.isEmpty ? "" : " " + event
        switch style {
        case .yearThenDay:
            return root.appendingPathComponent(s("yyyy"), isDirectory: true)
                .appendingPathComponent(s("yyyy-MM-dd") + suffix, isDirectory: true)
        case .yearThenMonth:
            return root.appendingPathComponent(s("yyyy"), isDirectory: true)
                .appendingPathComponent(s("yyyy-MM") + suffix, isDirectory: true)
        case .day:
            return root.appendingPathComponent(s("yyyy-MM-dd") + suffix, isDirectory: true)
        }
    }
}
