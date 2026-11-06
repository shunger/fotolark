import Foundation
import ImageIO

/// Changes to the details stored inside photo files.
public struct MetadataChanges: Codable, Equatable, Sendable {
    /// Moves the capture date by this many seconds (for a camera whose clock was wrong).
    public var shiftSeconds: TimeInterval = 0
    /// Keywords to add (kept alongside any already there).
    public var addKeywords: [String] = []
    /// Keywords to take out (any capitalization).
    public var removeKeywords: [String] = []
    public var removeLocation = false

    public init() {}

    public var isEmpty: Bool { shiftSeconds == 0 && addKeywords.isEmpty && removeKeywords.isEmpty && !removeLocation }

    enum CodingKeys: String, CodingKey { case shiftSeconds, addKeywords, removeKeywords, removeLocation }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shiftSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .shiftSeconds) ?? 0
        addKeywords = try c.decodeIfPresent([String].self, forKey: .addKeywords) ?? []
        removeKeywords = try c.decodeIfPresent([String].self, forKey: .removeKeywords) ?? []
        removeLocation = try c.decodeIfPresent(Bool.self, forKey: .removeLocation) ?? false
    }
}

/// Rewrites photo details without re-encoding the pixels.
///
/// This is the one bulk tool that changes original files, so each file is copied to the
/// backup folder first and the job can be undone from that copy.
public enum MetadataEditor {
    public enum Failure: LocalizedError {
        case unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .unsupported(let type): "Fotolark can’t change the details inside \(type) files."
            }
        }
    }

    public static func apply(_ changes: MetadataChanges, to photo: URL, backupDirectory: URL) throws -> [UndoStep] {
        guard !changes.isEmpty else { return [] }
        guard let src = CGImageSourceCreateWithURL(photo as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw FotolarkError.cannotRead(photo.lastPathComponent)
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()

        if changes.shiftSeconds != 0 {
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let pairs: [(CFString, CFString, String?)] = [
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, exif[kCGImagePropertyExifDateTimeOriginal] as? String),
                (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, exif[kCGImagePropertyExifDateTimeDigitized] as? String),
                (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFDateTime, tiff[kCGImagePropertyTIFFDateTime] as? String),
            ]
            for (dict, key, value) in pairs {
                guard let value, let shifted = shiftExifDate(value, by: changes.shiftSeconds) else { continue }
                CGImageMetadataSetValueMatchingImageProperty(metadata, dict, key, shifted as CFString)
            }
        }

        if !changes.addKeywords.isEmpty || !changes.removeKeywords.isEmpty {
            var all = PhotoMetadata.keywords(in: src)
            all.removeAll { k in changes.removeKeywords.contains { $0.caseInsensitiveCompare(k) == .orderedSame } }
            for k in changes.addKeywords where !all.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) {
                all.append(k)
            }
            if all.isEmpty {
                // Sets both the IPTC keywords and XMP dc:subject.
                CGImageMetadataRemoveTagWithPath(metadata, nil, "dc:subject" as CFString)
                CGImageMetadataRemoveTagWithPath(metadata, nil, "Iptc4xmpCore:Keywords" as CFString)
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary,
                                                             kCGImagePropertyIPTCKeywords, [String]() as CFArray)
            } else {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary,
                                                             kCGImagePropertyIPTCKeywords, all as CFArray)
            }
        }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw Failure.unsupported(photo.pathExtension.uppercased())
        }
        var options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        if changes.removeLocation { options[kCGImageMetadataShouldExcludeGPS] = true }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &error) else {
            throw Failure.unsupported(photo.pathExtension.uppercased())
        }

        let backup = try OriginalOverwriter.makeBackup(of: photo, in: backupDirectory, now: Date())
        var writeError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: photo, options: [], error: &coordError) { url in
            do { try (data as Data).write(to: url) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
        return [.restoreFile(backup: backup, original: photo)]
    }

    /// "2026:07:04 10:30:00" moved by `seconds`, in the same format.
    static func shiftExifDate(_ text: String, by seconds: TimeInterval) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let d = f.date(from: text) else { return nil }
        return f.string(from: d.addingTimeInterval(seconds))
    }
}
