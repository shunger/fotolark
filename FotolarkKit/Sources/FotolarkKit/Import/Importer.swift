import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo on a phone, camera, card or drive that could be imported.
public struct ImportCandidate: Hashable, Identifiable, Sendable {
    /// Stable within one device session.
    public let id: String
    public let name: String
    public let fileSize: Int64
    /// When it was taken (or created), if known.
    public let date: Date?
    public let typeIdentifier: String?

    public init(id: String, name: String, fileSize: Int64, date: Date?, typeIdentifier: String?) {
        self.id = id
        self.name = name
        self.fileSize = fileSize
        self.date = date
        self.typeIdentifier = typeIdentifier
    }

    /// The type the device reported, unless it's vague or unknown (devices differ), in
    /// which case the file name's extension decides.
    var type: UTType? {
        let byName = UTType(filenameExtension: (name as NSString).pathExtension)
        guard let reported = typeIdentifier.flatMap(UTType.init),
              reported.conforms(to: .image) || reported.conforms(to: .audiovisualContent) else { return byName }
        // A generic "image" from the device says less than a .HEIC or .JPG name does.
        if reported == .image, let byName, byName.conforms(to: .image) { return byName }
        return reported
    }

    /// Still photos are imported; videos and Live Photo clips arrive in Phase 3.
    public var isPhoto: Bool {
        guard let type else { return false }
        return type.conforms(to: .image)
    }

    public var isVideo: Bool {
        guard let type else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    /// File name without extension, for pairing a Live Photo's still with its clip.
    public var baseName: String { (name as NSString).deletingPathExtension.lowercased() }

    public var isHEIC: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "heic" || ext == "heif" { return true }
        guard let type else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif)
    }
}

public struct ImportOptions: Codable, Equatable, Sendable {
    /// Put photos in date folders (e.g. 2026/2026-11-06 Beach); nil = straight into the destination.
    public var dateFolders: DateFolderPattern?
    /// Rename as they come in; nil keeps the camera's names.
    public var rename: RenameRule?
    public var convertHEICToJPEG = false
    /// When converting, also keep the HEIC file.
    public var keepHEICOriginal = true
    public var jpegQuality = 0.92
    /// Leave out photos already imported before or already in the destination.
    public var skipDuplicates = true
    /// Also import videos (copied as they are).
    public var includeVideos = false
    /// For Live Photos, also import the short video clip next to the still.
    public var includeLiveClips = false

    public init() {}
}

/// Photos imported before, so "new only" and "skip duplicates" work across sessions.
/// Remembered by name, size and date, which identify a photo on a device reliably.
public final class ImportHistory: @unchecked Sendable {
    private var keys: Set<String>
    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        keys = (try? JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: fileURL))) ?? []
    }

    static func key(_ c: ImportCandidate) -> String {
        "\(c.name.lowercased())|\(c.fileSize)|\(Int(c.date?.timeIntervalSince1970 ?? 0))"
    }

    public func contains(_ c: ImportCandidate) -> Bool { lock.withLock { keys.contains(Self.key(c)) } }

    public func insert(_ c: ImportCandidate) { lock.withLock { _ = keys.insert(Self.key(c)) } }

    public func save() {
        let data = lock.withLock { try? JSONEncoder().encode(keys) }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: fileURL, options: .atomic)
    }
}

public enum Importer {
    /// Folder a candidate goes into.
    public static func folder(for c: ImportCandidate, options: ImportOptions, root: URL) -> URL {
        guard let pattern = options.dateFolders else { return root }
        return pattern.folder(for: c.date ?? Date(), in: root)
    }

    /// File name a candidate gets (before converting). `index` numbers the import.
    public static func fileName(for c: ImportCandidate, index: Int, options: ImportOptions) -> String {
        guard let rule = options.rename else { return c.name }
        return RenamePlan.newName(for: URL(fileURLWithPath: "/import").appendingPathComponent(c.name),
                                  index: index, date: c.date ?? Date(), rule: rule)
    }

    /// True if the photo was imported before, or a file of the same name and size is
    /// already where it would go.
    public static func isDuplicate(_ c: ImportCandidate, index: Int, options: ImportOptions, root: URL,
                                   history: ImportHistory) -> Bool {
        if history.contains(c) { return true }
        let existing = folder(for: c, options: options, root: root).appendingPathComponent(fileName(for: c, index: index, options: options))
        guard let size = try? existing.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(size) == c.fileSize
    }

    public struct Placed: Sendable {
        /// Files now in the destination.
        public var files: [URL]
        /// True when the copy checked out, so the original may be deleted from the device.
        public var verified: Bool
        public var undo: [UndoStep]
    }

    /// Moves a downloaded file into place, converting HEIC to JPEG if asked, and checks
    /// the result before the original may be deleted from the device.
    public static func place(_ downloaded: URL, candidate c: ImportCandidate, index: Int, options: ImportOptions,
                             root: URL, engine: EditEngine) throws -> Placed {
        let folder = folder(for: c, options: options, root: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = fileName(for: c, index: index, options: options)
        var placed = Placed(files: [], verified: false, undo: [])

        if c.isVideo {
            // Videos are copied as they are, and only renamed if asked.
            let target = PhotoFileOperations.availableURL(for: name, in: folder)
            try FileManager.default.moveItem(at: downloaded, to: target)
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            return Placed(files: [target], verified: c.fileSize <= 0 || size == c.fileSize, undo: [.removeCreatedFile(target)])
        }
        if options.convertHEICToJPEG && (c.isHEIC || isHEICFile(downloaded)) {
            let jpeg = try ImageExporter.encode(source: downloaded, recipe: EditRecipe(),
                                                options: ExportOptions(format: .jpeg, quality: options.jpegQuality),
                                                engine: engine)
            let jpegURL = PhotoFileOperations.availableURL(
                for: (name as NSString).deletingPathExtension + ".jpg", in: folder)
            try jpeg.write(to: jpegURL, options: .withoutOverwriting)
            placed.files.append(jpegURL)
            placed.undo.append(.removeCreatedFile(jpegURL))
            if options.keepHEICOriginal {
                let heicURL = PhotoFileOperations.availableURL(for: name, in: folder)
                try FileManager.default.moveItem(at: downloaded, to: heicURL)
                placed.files.append(heicURL)
                placed.undo.append(.removeCreatedFile(heicURL))
            } else {
                try? FileManager.default.removeItem(at: downloaded)
            }
            placed.verified = (try? ImageLoader.info(for: jpegURL)) != nil
        } else {
            let target = PhotoFileOperations.availableURL(for: name, in: folder)
            try FileManager.default.moveItem(at: downloaded, to: target)
            placed.files.append(target)
            placed.undo.append(.removeCreatedFile(target))
            let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            placed.verified = (c.fileSize <= 0 || size == c.fileSize) && (try? ImageLoader.info(for: target)) != nil
        }
        return placed
    }
}

extension Importer {
    /// Which candidates to show and import: stills always; Live Photo clips (videos with
    /// the same name as a still) only with `includeLiveClips`, and other videos only with
    /// `includeVideos`. Returns the stills/videos to show and, per still, its clip.
    public static func plan(_ all: [ImportCandidate], options: ImportOptions)
        -> (shown: [ImportCandidate], clips: [ImportCandidate.ID: ImportCandidate]) {
        let stillNames = Set(all.filter(\.isPhoto).map(\.baseName))
        var clipsByName: [String: ImportCandidate] = [:]
        var shown: [ImportCandidate] = []
        for c in all {
            if c.isPhoto {
                shown.append(c)
            } else if c.isVideo {
                if stillNames.contains(c.baseName) {
                    clipsByName[c.baseName] = c
                } else if options.includeVideos {
                    shown.append(c)
                }
            }
        }
        var clips: [ImportCandidate.ID: ImportCandidate] = [:]
        if options.includeLiveClips {
            for c in shown where c.isPhoto { if let clip = clipsByName[c.baseName] { clips[c.id] = clip } }
        }
        return (shown, clips)
    }
}

/// True when the file's contents are HEIC/HEIF, whatever the device said about it.
func isHEICFile(_ url: URL) -> Bool {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let id = CGImageSourceGetType(src) as String?, let type = UTType(id) else { return false }
    return type.conforms(to: .heic) || type.conforms(to: .heif)
}
