import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Makes and caches thumbnails, with edits applied, so big folders open quickly.
///
/// Thumbnails are kept in memory (up to a size limit) and as small JPEGs on disk. The
/// cache key includes the file's size and modification date and the edit recipe, so a
/// changed photo or a new edit gets a fresh thumbnail automatically.
public final class ThumbnailStore: @unchecked Sendable {
    /// Thumbnails are made at one of these sizes (longest side, pixels).
    public static let sizes = [256, 512]

    private let memory = NSCache<NSString, CGImage>()
    private let diskDirectory: URL?
    private let engine: EditEngine
    private let limiter: AsyncLimiter

    public init(diskDirectory: URL?, engine: EditEngine,
                maxConcurrent: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)) {
        self.diskDirectory = diskDirectory
        self.engine = engine
        limiter = AsyncLimiter(limit: maxConcurrent)
        memory.totalCostLimit = 256 * 1024 * 1024
        if let diskDirectory {
            try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        }
    }

    /// The size bucket used for a request.
    public static func bucket(for maxPixelSize: Int) -> Int {
        sizes.first { $0 >= maxPixelSize } ?? sizes.last!
    }

    /// A cached thumbnail, if one is already in memory (no waiting).
    public func cachedThumbnail(for photo: ScannedPhoto, recipe: EditRecipe?, maxPixelSize: Int) -> CGImage? {
        memory.object(forKey: key(photo, recipe: recipe, bucket: Self.bucket(for: maxPixelSize)) as NSString)
    }

    /// The thumbnail for `photo`, making it if needed. Returns nil if the task is
    /// cancelled (e.g. the cell scrolled away) or the file can't be read.
    public func thumbnail(for photo: ScannedPhoto, recipe: EditRecipe?, maxPixelSize: Int) async -> CGImage? {
        let bucket = Self.bucket(for: maxPixelSize)
        let k = key(photo, recipe: recipe, bucket: bucket)
        if let hit = memory.object(forKey: k as NSString) { return hit }

        await limiter.acquire()
        defer { Task { await limiter.release() } }
        if Task.isCancelled { return nil }
        if let hit = memory.object(forKey: k as NSString) { return hit }

        let image = loadFromDisk(k) ?? make(photo, recipe: recipe, bucket: bucket, key: k)
        if let image {
            memory.setObject(image, forKey: k as NSString, cost: image.bytesPerRow * image.height)
        }
        return image
    }

    /// Clears memory copies (disk copies are keyed by date and recipe, so they never go stale).
    public func removeAllFromMemory() {
        memory.removeAllObjects()
    }

    // MARK: Internals

    func key(_ photo: ScannedPhoto, recipe: EditRecipe?, bucket: Int) -> String {
        var text = "\(photo.url.standardizedFileURL.path)|\(photo.fileSize)|\(photo.modified.timeIntervalSince1970)|\(bucket)"
        if let recipe, !recipe.isEmpty, let data = try? JSONEncoder.sorted.encode(recipe) {
            text += "|" + String(decoding: data, as: UTF8.self)
        }
        return SHA256.hash(data: Data(text.utf8)).prefix(20).map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(_ key: String) -> URL? {
        diskDirectory?.appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent(key).appendingPathExtension("jpg")
    }

    private func loadFromDisk(_ key: String) -> CGImage? {
        guard let url = diskURL(key), let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func make(_ photo: ScannedPhoto, recipe: EditRecipe?, bucket: Int, key: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(photo.url as CFURL, nil) else { return nil }
        // Edits that crop need a little more resolution to start from.
        let sourceSize = recipe?.cropRect == nil ? bucket : bucket * 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sourceSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }

        if let recipe, !recipe.isEmpty {
            var edited = RecipeRenderer.apply(recipe, to: CIImage(cgImage: image), includeResize: false)
            let longest = max(edited.extent.width, edited.extent.height)
            if longest > CGFloat(bucket) {
                let s = CGFloat(bucket) / longest
                edited = edited.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
            }
            if let rendered = engine.makeCGImage(edited) { image = rendered }
        }

        if let url = diskURL(key) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                CGImageDestinationFinalize(dest)
            }
        }
        return image
    }
}

/// Lets at most `limit` tasks run at once; the most recent waiter goes first, so the
/// thumbnails just scrolled into view load before ones that scrolled past.
actor AsyncLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.popLast() {
            next.resume()
        } else {
            available += 1
        }
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }
}
