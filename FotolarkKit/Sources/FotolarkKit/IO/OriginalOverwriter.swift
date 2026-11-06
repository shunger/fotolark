import Foundation

/// "Save over original": bakes the edits into the photo file itself, after keeping a
/// backup copy of the untouched original.
public enum OriginalOverwriter {
    /// The format the original would be rewritten in, or nil when Fotolark can't write
    /// that format (GIF, WebP, BMP); those can only be exported as a copy.
    public static func format(for info: PhotoInfo) -> ExportFormat? {
        ExportFormat(typeIdentifier: info.typeIdentifier)
    }

    /// Replaces the photo with its edited version and returns where the backup went.
    public static func overwrite(photo: URL, recipe: EditRecipe, engine: EditEngine,
                                 backupDirectory: URL, now: Date = Date()) throws -> URL {
        let info = try ImageLoader.info(for: photo)
        guard let format = format(for: info) else {
            throw FotolarkError.cannotOverwrite(
                "Fotolark can’t save over \(photo.pathExtension.uppercased()) files. Use Export to save an edited copy.")
        }
        let options = ExportOptions(format: format, quality: 0.95,
                                    colorSpace: info.isWideGamut ? .displayP3 : .sRGB)
        // Encode first, so nothing is touched if that fails.
        let data = try ImageExporter.encode(source: photo, recipe: recipe, options: options, engine: engine)

        let backup = try makeBackup(of: photo, in: backupDirectory, now: now)

        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: photo, options: [], error: &coordError) { url in
            do { try data.write(to: url) } catch { writeError = error }
        }
        if let error = coordError ?? writeError { throw error }
        return backup
    }

    static func makeBackup(of photo: URL, in directory: URL, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let folder = directory.appendingPathComponent(formatter.string(from: now), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = photo.deletingPathExtension().lastPathComponent
        let ext = photo.pathExtension
        var target = folder.appendingPathComponent(photo.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        try FileManager.default.copyItem(at: photo, to: target)
        return target
    }
}
