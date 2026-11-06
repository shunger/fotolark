import CoreImage
import Foundation
import ImageIO
import Testing
@testable import FotolarkKit

@Suite("Folder scanning")
struct ScannerTests {
    /// root/a.jpg, root/2024/b.jpg, root/2024/Beach/c.png, root/2024/Empty/, root/10/d.jpg,
    /// root/2/e.jpg, root/.hidden/f.jpg, root/Lib.photoslibrary/g.jpg, root/notes.txt
    func makeTree() throws -> URL {
        let root = try makeTempDirectory()
        let fm = FileManager.default
        let grid = Grid.numbered(width: 2, height: 2)
        for dir in ["2024/Beach", "2024/Empty", "10", "2", ".hidden", "Lib.photoslibrary"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try writePhoto(grid, to: root.appendingPathComponent("a.jpg"))
        try writePhoto(grid, to: root.appendingPathComponent("2024/b.jpg"))
        try writePhoto(grid, to: root.appendingPathComponent("2024/Beach/c.png"), type: .png)
        try writePhoto(grid, to: root.appendingPathComponent("10/d.jpg"))
        try writePhoto(grid, to: root.appendingPathComponent("2/e.jpg"))
        try writePhoto(grid, to: root.appendingPathComponent(".hidden/f.jpg"))
        try writePhoto(grid, to: root.appendingPathComponent("Lib.photoslibrary/g.jpg"))
        try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        return root
    }

    @Test func listsFoldersWithPhotosInFinderOrder() throws {
        let root = try makeTree()
        let folders = PhotoScanner.folders(under: root)
        let names = folders.map { $0.url.path.replacingOccurrences(of: root.standardizedFileURL.path, with: "") }
        #expect(names == ["", "/2", "/10", "/2024", "/2024/Beach"])
        #expect(folders.map(\.depth) == [0, 1, 1, 1, 2])
        #expect(folders.map(\.photoCount) == [1, 1, 1, 1, 1])
    }

    @Test func photosInFolderAreDirectChildrenOnly() throws {
        let root = try makeTree()
        let names = PhotoScanner.photos(in: root.appendingPathComponent("2024")).map(\.name)
        #expect(names == ["b.jpg"])
    }

    @Test func sortOrders() {
        let d = Date(timeIntervalSince1970: 1_000_000)
        let a = ScannedPhoto(url: URL(fileURLWithPath: "/x/IMG 10.jpg"), fileSize: 5, modified: d, created: d)
        let b = ScannedPhoto(url: URL(fileURLWithPath: "/x/IMG 2.jpg"), fileSize: 9, modified: d, created: d.addingTimeInterval(10))
        let c = ScannedPhoto(url: URL(fileURLWithPath: "/x/IMG 3.jpg"), fileSize: 1, modified: d, created: d.addingTimeInterval(20))
        #expect(PhotoSortOrder.name.sorted([a, b, c]).map(\.name) == ["IMG 2.jpg", "IMG 3.jpg", "IMG 10.jpg"])
        #expect(PhotoSortOrder.size.sorted([a, b, c]).map(\.name) == ["IMG 2.jpg", "IMG 10.jpg", "IMG 3.jpg"])
        // Capture date wins over file date when known.
        let dates = [c.url: d.addingTimeInterval(-100)]
        #expect(PhotoSortOrder.dateTaken.sorted([a, b, c], dates: dates).map(\.name) == ["IMG 3.jpg", "IMG 10.jpg", "IMG 2.jpg"])
    }
}

@Suite("Photo metadata")
struct MetadataTests {
    @Test func readsCameraDataAndLocation() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("m.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:07:04 10:30:00",
                kCGImagePropertyExifOffsetTimeOriginal: "-07:00",
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifISOSpeedRatings: [100],
                kCGImagePropertyExifFocalLength: 50.0,
                kCGImagePropertyExifLensModel: "Test Lens 50mm",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Canon",
                kCGImagePropertyTIFFModel: "Canon EOS R6",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 47.6062, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.3321, kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ]
        CGImageDestinationAddImage(dest, Grid.numbered(width: 4, height: 2).cgImage, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        let m = PhotoMetadata.read(url)
        #expect(m.pixelSize == PixelSize(width: 4, height: 2))
        #expect(m.dateTaken == ISO8601DateFormatter().date(from: "2026-07-04T17:30:00Z"))
        #expect(m.cameraName == "Canon EOS R6")
        #expect(m.lens == "Test Lens 50mm")
        #expect(m.exposureSummary == "1/250 s · f/2.8 · ISO 100 · 50 mm")
        #expect(m.coordinatesText == "47.6062° N, 122.3321° W")
    }

    @Test func missingDataIsNil() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("plain.png")
        try writePhoto(Grid.numbered(width: 2, height: 2), to: url, type: .png)
        let m = PhotoMetadata.read(url)
        #expect(m.dateTaken == nil && m.cameraName == nil && m.coordinatesText == nil && m.exposureSummary == nil)
    }
}

@Suite("Thumbnails")
struct ThumbnailTests {
    func photo(in dir: URL, size: (Int, Int) = (1200, 800)) throws -> ScannedPhoto {
        let url = dir.appendingPathComponent("t.jpg")
        let cg = testEngine.makeCGImage(solid(r: 0.2, g: 0.5, b: 0.8, width: size.0, height: size.1))!
        try writePhoto(readGrid(cg), to: url)
        return PhotoScanner.photos(in: dir)[0]
    }

    @Test func makesSmallThumbnailAndCachesOnDisk() async throws {
        let dir = try makeTempDirectory()
        let cache = dir.appendingPathComponent("cache")
        let p = try photo(in: dir)
        let store = ThumbnailStore(diskDirectory: cache, engine: testEngine)
        let thumb = try #require(await store.thumbnail(for: p, recipe: nil, maxPixelSize: 200))
        #expect(max(thumb.width, thumb.height) == 256)
        // A second store (e.g. next launch) finds it on disk.
        let files = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)?.allObjects ?? []
        #expect(files.contains { ($0 as? URL)?.pathExtension == "jpg" })
        let again = ThumbnailStore(diskDirectory: cache, engine: testEngine)
        #expect(await again.thumbnail(for: p, recipe: nil, maxPixelSize: 200) != nil)
    }

    @Test func thumbnailShowsEdits() async throws {
        let dir = try makeTempDirectory()
        let p = try photo(in: dir)
        let store = ThumbnailStore(diskDirectory: nil, engine: testEngine)
        let turned = EditRecipe().rotated(clockwise: true)
        let thumb = try #require(await store.thumbnail(for: p, recipe: turned, maxPixelSize: 256))
        #expect(thumb.height > thumb.width)
        #expect(store.cachedThumbnail(for: p, recipe: turned, maxPixelSize: 256) != nil)
        #expect(store.cachedThumbnail(for: p, recipe: nil, maxPixelSize: 256) == nil)
    }

    @Test func keyChangesWhenFileOrRecipeChanges() {
        let store = ThumbnailStore(diskDirectory: nil, engine: testEngine)
        let d = Date()
        let p = ScannedPhoto(url: URL(fileURLWithPath: "/a.jpg"), fileSize: 10, modified: d, created: d)
        let newer = ScannedPhoto(url: p.url, fileSize: 10, modified: d.addingTimeInterval(1), created: d)
        let k = store.key(p, recipe: nil, bucket: 256)
        #expect(k != store.key(newer, recipe: nil, bucket: 256))
        #expect(k != store.key(p, recipe: EditRecipe().rotated(clockwise: true), bucket: 256))
        #expect(k == store.key(p, recipe: EditRecipe(), bucket: 256))
    }
}

@Suite("File operations")
struct FileOperationTests {
    func setUp() throws -> (URL, RecipeStore, PhotoFileOperations) {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent(".fallback"))
        return (dir, store, PhotoFileOperations(store: store))
    }

    @Test func renameKeepsEditsAndExtension() throws {
        let (dir, store, ops) = try setUp()
        let photo = dir.appendingPathComponent("IMG_1.jpg")
        try writePhoto(Grid.numbered(width: 2, height: 2), to: photo)
        let recipe = EditRecipe().rotated(clockwise: true)
        try store.save(recipe, for: photo)

        let renamed = try ops.rename(photo, to: "Beach day")
        #expect(renamed.lastPathComponent == "Beach day.jpg")
        #expect(store.load(for: renamed) == recipe)
        #expect(store.load(for: photo) == nil)
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: photo).path))
    }

    @Test func renameRefusesTakenAndBadNames() throws {
        let (dir, _, ops) = try setUp()
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        try writePhoto(Grid.numbered(width: 2, height: 2), to: a)
        try writePhoto(Grid.numbered(width: 2, height: 2), to: b)
        #expect(throws: PhotoFileOperations.OperationError.nameTaken("b.jpg")) { try ops.rename(a, to: "b") }
        #expect(throws: PhotoFileOperations.OperationError.invalidName) { try ops.rename(a, to: "x/y") }
        // Changing only capitalization is allowed.
        #expect(try ops.rename(a, to: "A.jpg").lastPathComponent == "A.jpg")
    }

    @Test func moveAndCopyCarryEditsAndAvoidNameClashes() throws {
        let (dir, store, ops) = try setUp()
        let dest = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("p.jpg")
        try writePhoto(Grid.numbered(width: 2, height: 2), to: photo)
        try writePhoto(Grid.numbered(width: 2, height: 2), to: dest.appendingPathComponent("p.jpg"))
        let recipe = EditRecipe().setting(.straighten(degrees: 2))
        try store.save(recipe, for: photo)

        let copied = try ops.copy([photo], to: dest)
        #expect(copied.map(\.lastPathComponent) == ["p 2.jpg"])
        #expect(store.load(for: copied[0]) == recipe)
        #expect(store.load(for: photo) == recipe)

        let moved = try ops.move([photo], to: dest)
        #expect(moved.map(\.lastPathComponent) == ["p 3.jpg"])
        #expect(store.load(for: moved[0]) == recipe)
        #expect(!FileManager.default.fileExists(atPath: photo.path))
    }

    @Test func libraryModeKeepsEditsOutOfPhotoFolders() throws {
        let (dir, store, _) = try setUp()
        let photo = dir.appendingPathComponent("q.jpg")
        let recipe = EditRecipe().rotated(clockwise: false)
        try store.save(recipe, for: photo)  // sidecar first
        store.usesSidecars = false
        let location = try store.save(recipe.setting(.straighten(degrees: 1)), for: photo)
        guard case .appStorage = location else { Issue.record("expected library, got \(location)"); return }
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: photo).path))
        #expect(store.load(for: photo)?.straightenDegrees == 1)
        try store.save(EditRecipe(), for: photo)
        #expect(store.load(for: photo) == nil)
    }
}

@Suite("Bulk recipe loading")
struct BulkRecipeTests {
    @Test func loadsSidecarsAndLibraryEntries() throws {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent(".fallback"))
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.heic")
        let c = dir.appendingPathComponent("c.jpg"), d = dir.appendingPathComponent("a.heic")
        let r1 = EditRecipe().rotated(clockwise: true), r2 = EditRecipe().setting(.straighten(degrees: 3))
        try store.save(r1, for: a)
        try store.save(r2, for: d)  // shares a.fotolark with a.jpg
        store.usesSidecars = false
        try store.save(r2, for: b)
        let all = store.recipes(for: [a, b, c, d])
        #expect(all == [a: r1, b: r2, d: r2])
    }
}
