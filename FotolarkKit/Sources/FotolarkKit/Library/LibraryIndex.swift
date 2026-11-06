import CoreImage
import Foundation
import Vision

/// What the index knows about one photo, for search and the timeline.
public struct IndexedPhoto: Codable, Equatable, Sendable {
    public var path: String
    public var size: Int64
    public var modified: Date
    public var created: Date
    public var dateTaken: Date?
    public var camera: String?
    /// Keywords stored in the file by other apps.
    public var keywords: [String]
    public var labels: PhotoLabels
    /// Text read from the picture (signs, documents, screenshots); nil until read.
    public var text: String?

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
    /// When it was taken, or else when the file was made.
    public var date: Date { dateTaken ?? created }

    public var scanned: ScannedPhoto {
        ScannedPhoto(url: url, fileSize: size, modified: modified, created: created)
    }
}

/// A catalog of every photo in the watched folders, kept up to date in the background
/// and saved between launches. It holds only details for finding photos; the photos,
/// edits and labels themselves stay where they are.
public final class LibraryIndex: @unchecked Sendable {
    private var entries: [String: IndexedPhoto]
    /// Lowercased, accent-free text to search per photo (rebuilt, not saved).
    private var haystacks: [String: String] = [:]
    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        entries = (try? JSONDecoder().decode([String: IndexedPhoto].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    public var count: Int { lock.withLock { entries.count } }

    /// Every indexed photo, newest first.
    public var all: [IndexedPhoto] {
        lock.withLock { Array(entries.values) }.sorted { $0.date != $1.date ? $0.date > $1.date : $0.path < $1.path }
    }

    public func entry(for url: URL) -> IndexedPhoto? {
        lock.withLock { entries[url.standardizedFileURL.path] }
    }

    // MARK: Updating

    /// Brings the index in line with the photos under `roots`: adds new photos, re-reads
    /// changed ones, drops ones that are gone (and any outside the roots), and refreshes
    /// labels. Returns true if anything changed.
    @discardableResult
    public func refresh(roots: [URL], store: RecipeStore, isCancelled: () -> Bool = { false }) -> Bool {
        var found: [ScannedPhoto] = []
        for root in roots {
            found += PhotoScanner.allPhotos(under: root)
            if isCancelled() { return false }
        }
        let known = lock.withLock { entries }
        var next: [String: IndexedPhoto] = [:]
        for photo in found {
            if isCancelled() { return false }
            let path = photo.url.standardizedFileURL.path
            if var old = known[path], old.modified == photo.modified, old.size == photo.fileSize {
                old.created = photo.created
                next[path] = old
                continue
            }
            let m = PhotoMetadata.read(photo.url)
            next[path] = IndexedPhoto(path: path, size: photo.fileSize, modified: photo.modified, created: photo.created,
                                      dateTaken: m.dateTaken, camera: m.cameraName, keywords: m.keywords,
                                      labels: PhotoLabels(), text: nil)
        }
        let records = store.records(for: found.map(\.url))
        for (url, record) in records {
            next[url.standardizedFileURL.path]?.labels = record.labels
        }
        let changed = lock.withLock { () -> Bool in
            let changed = next != entries
            entries = next
            haystacks = [:]
            return changed
        }
        if changed { save() }
        return changed
    }

    /// Records a rating, flag or tag change made in the app right away.
    public func updateLabels(_ labels: PhotoLabels, for url: URL) {
        lock.withLock {
            let path = url.standardizedFileURL.path
            guard entries[path] != nil else { return }
            entries[path]?.labels = labels
            haystacks[path] = nil
        }
    }

    /// Photos whose text hasn't been read yet, newest first.
    public func photosNeedingText() -> [URL] {
        all.filter { $0.text == nil }.map(\.url)
    }

    public func setText(_ text: String, for url: URL) {
        lock.withLock {
            let path = url.standardizedFileURL.path
            entries[path]?.text = text
            haystacks[path] = nil
        }
    }

    public func save() {
        let data = lock.withLock { try? JSONEncoder().encode(entries) }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: fileURL, options: .atomic)
    }

    // MARK: Searching

    /// Photos matching every word of `query`, newest first. A word matches the name,
    /// folder, tags, keywords, camera or text in the photo; a year ("2024") or month
    /// ("July") matches when it was taken. "Quoted words" match as a phrase.
    public func search(_ query: String) -> [IndexedPhoto] {
        let terms = SearchTerms(query)
        guard !terms.isEmpty else { return [] }
        let photos = all
        return lock.withLock {
            photos.filter { p in
                let hay = haystacks[p.path] ?? {
                    let h = Self.haystack(for: p)
                    haystacks[p.path] = h
                    return h
                }()
                return terms.matches(p, haystack: hay)
            }
        }
    }

    static func haystack(for p: IndexedPhoto) -> String {
        let folder = ((p.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let parts = [p.name, folder, p.camera ?? "", p.text ?? ""] + p.labels.tags + p.keywords
        return SearchTerms.fold(parts.joined(separator: "\n"))
    }

    // MARK: Reading text in photos

    /// Text Vision finds in the photo, one line per piece of text ("" if none).
    public static func recognizeText(in url: URL) -> String {
        guard let image = try? ImageLoader.loadPreview(url, maxPixelSize: 1600) else { return "" }
        return recognizeText(in: image)
    }

    public static func recognizeText(in image: CIImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.02
        let handler = VNImageRequestHandler(ciImage: image.normalizedToOrigin(), options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        return (request.results ?? [])
            .filter { $0.topCandidates(1).first.map { $0.confidence >= 0.3 } ?? false }
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

/// The words of a search, ready to match.
struct SearchTerms {
    var words: [String] = []
    var years: [Int] = []
    var months: [Int] = []

    init(_ query: String) {
        // Split into words, keeping "quoted phrases" together.
        var tokens: [String] = []
        for (i, part) in query.components(separatedBy: "\"").enumerated() {
            if i % 2 == 1 {
                let phrase = part.trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { tokens.append(phrase) }
            } else {
                tokens += part.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            }
        }
        let monthNames = Self.monthNames
        for t in tokens {
            let f = Self.fold(t)
            if let y = Int(f), f.count == 4, (1900...2100).contains(y) {
                years.append(y)
            } else if let m = monthNames[f] {
                months.append(m)
            } else {
                words.append(f)
            }
        }
    }

    var isEmpty: Bool { words.isEmpty && years.isEmpty && months.isEmpty }

    func matches(_ p: IndexedPhoto, haystack: String) -> Bool {
        if !years.isEmpty || !months.isEmpty {
            let c = Calendar.current.dateComponents([.year, .month], from: p.date)
            if !years.allSatisfy({ $0 == c.year }) || !months.allSatisfy({ $0 == c.month }) {
                // A year or month name may also be part of a name or caption.
                let asWords = years.map(String.init) + months.map { Self.monthNameList[$0 - 1] }
                if !asWords.allSatisfy({ haystack.contains($0) }) { return false }
            }
        }
        return words.allSatisfy { haystack.contains($0) }
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
    }

    static let monthNameList: [String] = {
        let f = DateFormatter()
        f.locale = .current
        return (f.monthSymbols ?? []).map(fold)
    }()

    /// Full and short month names, in the person's language and in English.
    static let monthNames: [String: Int] = {
        var out: [String: Int] = [:]
        for locale in [Locale.current, Locale(identifier: "en_US_POSIX")] {
            let f = DateFormatter()
            f.locale = locale
            for (i, n) in (f.monthSymbols ?? []).enumerated() { out[fold(n)] = i + 1 }
            for (i, n) in (f.shortMonthSymbols ?? []).enumerated() { out[fold(n).trimmingCharacters(in: .punctuationCharacters)] = i + 1 }
        }
        return out
    }()
}

extension PhotoScanner {
    /// Every photo under `root`, in all subfolders. Hidden folders and packages are skipped.
    public static func allPhotos(under root: URL) -> [ScannedPhoto] {
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            return []
        }
        var out: [ScannedPhoto] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true {
                if v.isPackage == true { e.skipDescendants() }
                continue
            }
            guard ImageLoader.canOpen(url) else { continue }
            out.append(ScannedPhoto(url: url.standardizedFileURL, fileSize: Int64(v.fileSize ?? 0),
                                    modified: v.contentModificationDate ?? .distantPast,
                                    created: v.creationDate ?? v.contentModificationDate ?? .distantPast))
        }
        return out
    }
}
