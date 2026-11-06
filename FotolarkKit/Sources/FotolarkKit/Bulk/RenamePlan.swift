import Foundation

/// How a bulk rename makes new names.
public struct RenameRule: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Identifiable, Sendable {
        case pattern, findReplace, changeCase
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .pattern: "Pattern"
            case .findReplace: "Find and replace"
            case .changeCase: "Change case"
            }
        }
    }

    public enum TextCase: String, Codable, CaseIterable, Identifiable, Sendable {
        case lower, upper, title
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .lower: "lowercase"
            case .upper: "UPPERCASE"
            case .title: "Title Case"
            }
        }
    }

    public var mode: Mode = .pattern
    /// Tokens: {name} original name, {date} 2026-11-06, {time} 14-30-05, {number} counter,
    /// {folder} the folder's name.
    public var pattern = "{name}"
    public var startNumber = 1
    /// Minimum digits for {number}, e.g. 3 → 001.
    public var digits = 3
    public var find = ""
    public var replace = ""
    public var caseSensitive = false
    public var textCase: TextCase = .lower
    /// Also lowercase the extension (e.g. .JPG → .jpg).
    public var lowercaseExtension = false

    public init() {}

    public static let tokens = ["{name}", "{date}", "{time}", "{number}", "{folder}"]
}

/// One line of a rename preview.
public struct RenamePreviewItem: Equatable, Sendable, Identifiable {
    public var id: URL { source }
    public let source: URL
    public let newName: String
    /// Why this name can't be used, if it can't.
    public let problem: String?

    public var isUnchanged: Bool { newName == source.lastPathComponent }
}

public enum RenamePlan {
    /// New names for `photos` (in the order given, which sets {number}).
    public static func preview(_ rule: RenameRule, photos: [URL], dates: [URL: Date]) -> [RenamePreviewItem] {
        let dateF = DateFormatter()
        dateF.locale = Locale(identifier: "en_US_POSIX")
        var names: [String] = []
        for (i, url) in photos.enumerated() {
            let date = dates[url] ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            names.append(newName(for: url, index: i, date: date, rule: rule, formatter: dateF))
        }
        return check(photos: photos, names: names)
    }

    /// The new name for one photo. `index` sets {number}.
    public static func newName(for url: URL, index i: Int, date: Date, rule: RenameRule) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return newName(for: url, index: i, date: date, rule: rule, formatter: f)
    }

    static func newName(for url: URL, index i: Int, date: Date, rule: RenameRule, formatter dateF: DateFormatter) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        var ext = url.pathExtension
        if rule.lowercaseExtension { ext = ext.lowercased() }
        var newBase: String
        switch rule.mode {
        case .pattern:
            dateF.dateFormat = "yyyy-MM-dd"
            let day = dateF.string(from: date)
            dateF.dateFormat = "HH-mm-ss"
            let time = dateF.string(from: date)
            let number = String(rule.startNumber + i)
            let padded = String(repeating: "0", count: max(0, rule.digits - number.count)) + number
            newBase = rule.pattern
                .replacingOccurrences(of: "{name}", with: base)
                .replacingOccurrences(of: "{date}", with: day)
                .replacingOccurrences(of: "{time}", with: time)
                .replacingOccurrences(of: "{number}", with: padded)
                .replacingOccurrences(of: "{folder}", with: url.deletingLastPathComponent().lastPathComponent)
        case .findReplace:
            newBase = rule.find.isEmpty ? base : base.replacingOccurrences(
                of: rule.find, with: rule.replace, options: rule.caseSensitive ? [] : [.caseInsensitive])
        case .changeCase:
            switch rule.textCase {
            case .lower: newBase = base.lowercased()
            case .upper: newBase = base.uppercased()
            case .title: newBase = base.capitalized
            }
        }
        newBase = newBase.trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? newBase : newBase + "." + ext
    }

    static func check(photos: [URL], names: [String]) -> [RenamePreviewItem] {

        // Problems: bad names, two photos given the same name, or a name already used by
        // another file in that folder (one that isn't being renamed).
        let renamedPaths = Set(photos.map { $0.standardizedFileURL.path.lowercased() })
        var seen: [String: Int] = [:]
        for (url, name) in zip(photos, names) {
            seen[url.deletingLastPathComponent().appendingPathComponent(name).path.lowercased(), default: 0] += 1
        }
        return zip(photos, names).map { url, name in
            let base = (name as NSString).deletingPathExtension
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            let key = target.path.lowercased()
            var problem: String?
            if base.isEmpty {
                problem = "The name is empty"
            } else if name.contains("/") || name.contains(":") || name.hasPrefix(".") {
                problem = "Names can’t contain “/” or “:” or start with “.”"
            } else if seen[key, default: 0] > 1 {
                problem = "Another photo would get the same name"
            } else if !renamedPaths.contains(target.standardizedFileURL.path.lowercased()),
                      FileManager.default.fileExists(atPath: target.path) {
                problem = "A file with this name already exists"
            }
            return RenamePreviewItem(source: url, newName: name, problem: problem)
        }
    }

    /// Renames the photos as previewed. Items with a problem, or unchanged, are skipped.
    /// Works in two steps (to temporary names, then final ones) so names can be swapped.
    public static func apply(_ items: [RenamePreviewItem], store: RecipeStore,
                             progress: @Sendable (Int) -> Void = { _ in }) -> BulkResult {
        var result = BulkResult()
        let todo = items.filter { $0.problem == nil && !$0.isUnchanged }
        for item in items where item.problem != nil {
            result.skipped.append(SkippedItem(name: item.source.lastPathComponent, reason: item.problem!))
        }
        // Lift every record (edits, rating, tags) off first, so moving them can't
        // overwrite one another.
        var recipes: [URL: PhotoRecord] = [:]
        for item in todo {
            let r = store.loadRecord(for: item.source)
            if !r.isEmpty {
                recipes[item.source] = r
                _ = try? store.saveRecord(PhotoRecord(), for: item.source)
            }
        }
        var staged: [(item: RenamePreviewItem, temp: URL)] = []
        for item in todo {
            let temp = item.source.deletingLastPathComponent()
                .appendingPathComponent(".fotolark-rename-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: item.source, to: temp)
                staged.append((item, temp))
            } catch {
                result.skipped.append(SkippedItem(name: item.source.lastPathComponent, reason: error.localizedDescription))
                if let r = recipes[item.source] { _ = try? store.saveRecord(r, for: item.source) }
            }
        }
        for (item, temp) in staged {
            let target = item.source.deletingLastPathComponent().appendingPathComponent(item.newName)
            do {
                try FileManager.default.moveItem(at: temp, to: target)
                if let r = recipes[item.source] { _ = try? store.saveRecord(r, for: target) }
                result.undo.append(.moveBack(current: target, original: item.source))
            } catch {
                // Put it back under its old name.
                try? FileManager.default.moveItem(at: temp, to: item.source)
                if let r = recipes[item.source] { _ = try? store.saveRecord(r, for: item.source) }
                result.skipped.append(SkippedItem(name: item.source.lastPathComponent, reason: error.localizedDescription))
            }
            result.completed += 1
            progress(result.completed)
        }
        return result
    }
}
