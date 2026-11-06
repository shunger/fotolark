import Foundation

/// A photo file found on disk.
public struct ScannedPhoto: Hashable, Sendable, Identifiable {
    public let url: URL
    public let fileSize: Int64
    public let modified: Date
    public let created: Date

    public var id: URL { url }
    public var name: String { url.lastPathComponent }

    public init(url: URL, fileSize: Int64, modified: Date, created: Date) {
        self.url = url
        self.fileSize = fileSize
        self.modified = modified
        self.created = created
    }
}

/// A folder that holds photos directly inside it.
public struct ScannedFolder: Hashable, Sendable, Identifiable {
    public let url: URL
    /// 0 for the folder the person added, 1 for its subfolders, and so on.
    public let depth: Int
    public let photoCount: Int

    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

/// Finds photos in folders. Photos stay where they are; nothing is imported.
public enum PhotoScanner {
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isHiddenKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey,
    ]

    /// Every folder under `root` (including `root` itself) that holds photos, or holds
    /// folders that do, in display order: each folder followed by its subfolders, names sorted naturally.
    /// Hidden folders and packages (such as a Photos library) are skipped.
    public static func folders(under root: URL) -> [ScannedFolder] {
        var counts: [URL: Int] = [:]
        var allFolders: Set<URL> = [root.standardizedFileURL]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: options) else {
            return []
        }
        for case let url as URL in e {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true {
                if values?.isPackage == true { e.skipDescendants() } else { allFolders.insert(url.standardizedFileURL) }
            } else if ImageLoader.canOpen(url) {
                counts[url.deletingLastPathComponent().standardizedFileURL, default: 0] += 1
            }
        }
        let rootURL = root.standardizedFileURL
        let rootPath = rootURL.pathComponents
        // Folders with photos, plus the folders between them and the root (such as a
        // "2026" folder holding date folders), so the list matches what's on disk.
        var withPhotos: Set<URL> = [rootURL]
        for folder in allFolders where counts[folder, default: 0] > 0 {
            var f = folder
            while f.pathComponents.count > rootPath.count, withPhotos.insert(f).inserted {
                f = f.deletingLastPathComponent().standardizedFileURL
            }
        }
        return withPhotos
            .sorted { naturalPathOrder($0, $1) }
            .map { ScannedFolder(url: $0, depth: $0.pathComponents.count - rootPath.count,
                                 photoCount: counts[$0, default: 0]) }
    }

    /// Photos directly inside `folder` (not in subfolders).
    public static func photos(in folder: URL) -> [ScannedPhoto] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return contents.compactMap { url in
            guard ImageLoader.canOpen(url),
                  let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.isDirectory != true
            else { return nil }
            return ScannedPhoto(url: url, fileSize: Int64(v.fileSize ?? 0),
                                modified: v.contentModificationDate ?? .distantPast,
                                created: v.creationDate ?? v.contentModificationDate ?? .distantPast)
        }
    }

    /// Orders paths folder by folder, comparing names the way Finder does (2 before 10).
    static func naturalPathOrder(_ a: URL, _ b: URL) -> Bool {
        let pa = a.pathComponents, pb = b.pathComponents
        for (x, y) in zip(pa, pb) where x != y {
            return x.localizedStandardCompare(y) == .orderedAscending
        }
        return pa.count < pb.count
    }
}

/// How the grid and filmstrip order photos.
public enum PhotoSortOrder: String, CaseIterable, Codable, Identifiable, Sendable {
    case dateTaken, name, size

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dateTaken: "Date taken"
        case .name: "Name"
        case .size: "Size"
        }
    }

    /// Sorts photos. `dates` holds known capture dates; photos without one use the
    /// file's creation date.
    public func sorted(_ photos: [ScannedPhoto], dates: [URL: Date] = [:]) -> [ScannedPhoto] {
        switch self {
        case .name:
            return photos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            // Largest first.
            return photos.sorted {
                $0.fileSize != $1.fileSize ? $0.fileSize > $1.fileSize
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .dateTaken:
            return photos.sorted {
                let da = dates[$0.url] ?? $0.created, db = dates[$1.url] ?? $1.created
                return da == db ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : da < db
            }
        }
    }
}
