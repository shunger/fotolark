import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FotolarkKit

@Suite("Loading and exporting")
struct ExportTests {
    @Test func loaderAppliesCameraOrientation() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("turned.png")
        // Orientation 6 = shown turned a quarter clockwise.
        try writePhoto(Grid.numbered(width: 4, height: 2), to: url, type: .png, orientation: 6)
        let info = try ImageLoader.info(for: url)
        #expect(info.pixelSize == PixelSize(width: 2, height: 4))
        let full = try ImageLoader.loadFull(url)
        #expect(PixelSize(full.extent.size) == PixelSize(width: 2, height: 4))
        #expect(close(readGrid(full), Grid.numbered(width: 4, height: 2).rotatedClockwise()))
        let preview = try ImageLoader.loadPreview(url, maxPixelSize: 100)
        #expect(PixelSize(preview.extent.size) == PixelSize(width: 2, height: 4))
    }

    @Test func previewIsDownsized() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("big.jpg")
        let cg = testEngine.makeCGImage(solid(r: 0.3, g: 0.4, b: 0.5, width: 3000, height: 2000))!
        try writePhoto(readGrid(cg), to: url)
        let preview = try ImageLoader.loadPreview(url, maxPixelSize: 600)
        #expect(PixelSize(preview.extent.size) == PixelSize(width: 600, height: 400))
    }

    @Test func exportWritesUprightEditedPixelsAndKeepsCameraData() throws {
        let dir = try makeTempDirectory()
        let source = dir.appendingPathComponent("IMG_0001.jpg")
        try writePhoto(Grid.numbered(width: 4, height: 2), to: source, orientation: 6,
                       dateTaken: "2026:07:04 10:30:00")
        let recipe = EditRecipe().setting(.crop(CropRect(x: 0, y: 0, width: 1, height: 0.5)))
        let out = dir.appendingPathComponent("out.png")
        try ImageExporter.export(source: source, recipe: recipe,
                                 options: ExportOptions(format: .png), to: out, engine: testEngine)

        let src = CGImageSourceCreateWithURL(out as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 2)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 2)
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:07:04 10:30:00")
    }

    @Test(arguments: ExportFormat.allCases)
    func everyFormatEncodes(format: ExportFormat) throws {
        guard ImageExporter.availableFormats.contains(format) else { return }
        let dir = try makeTempDirectory()
        let source = dir.appendingPathComponent("a.png")
        let cg = testEngine.makeCGImage(solid(r: 0.3, g: 0.4, b: 0.5, width: 64, height: 64))!
        try writePhoto(readGrid(cg), to: source, type: .png)
        let data = try ImageExporter.encode(source: source, recipe: EditRecipe(),
                                            options: ExportOptions(format: format, quality: 0.8),
                                            engine: testEngine)
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        #expect(UTType(CGImageSourceGetType(src)! as String)!.conforms(to: format.utType))
    }

    @Test func webpCannotBeWritten() {
        // Apple's frameworks read WebP but have no encoder; Fotolark only converts from it.
        #expect(ExportFormat(typeIdentifier: UTType.webP.identifier) == nil)
    }
}

@Suite("Sidecar files")
struct SidecarTests {
    @Test func saveAndLoadThroughSidecar() throws {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("fallback"))
        let photo = dir.appendingPathComponent("IMG_0001.jpg")
        try writePhoto(Grid.numbered(width: 2, height: 2), to: photo)
        let recipe = EditRecipe().setting(.straighten(degrees: 2))

        let location = try store.save(recipe, for: photo)
        #expect(location == .sidecar(dir.appendingPathComponent("IMG_0001.fotolark")))
        #expect(store.load(for: photo) == recipe)
    }

    @Test func photosWithTheSameBaseNameShareOneSidecar() throws {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("fallback"))
        let jpg = dir.appendingPathComponent("IMG_0002.jpg")
        let heic = dir.appendingPathComponent("IMG_0002.heic")
        let a = EditRecipe().setting(.straighten(degrees: 1))
        let b = EditRecipe().setting(.straighten(degrees: -1))
        try store.save(a, for: jpg)
        try store.save(b, for: heic)
        #expect(store.load(for: jpg) == a)
        #expect(store.load(for: heic) == b)

        let file = try JSONDecoder().decode(SidecarFile.self,
                                            from: Data(contentsOf: RecipeStore.sidecarURL(for: jpg)))
        #expect(file.photos.count == 2)

        // Reverting both removes the sidecar.
        try store.save(EditRecipe(), for: jpg)
        #expect(FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: jpg).path))
        #expect(try store.save(EditRecipe(), for: heic) == .removed)
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: jpg).path))
    }

    @Test func unreadableSidecarIsNeverOverwritten() throws {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("fallback"))
        let photo = dir.appendingPathComponent("IMG_0003.jpg")
        let sidecar = RecipeStore.sidecarURL(for: photo)
        try Data("not json".utf8).write(to: sidecar)

        let recipe = EditRecipe().setting(.straighten(degrees: 5))
        let location = try store.save(recipe, for: photo)
        guard case .appStorage = location else { Issue.record("expected app storage, got \(location)"); return }
        #expect(try String(contentsOf: sidecar, encoding: .utf8) == "not json")
        #expect(store.load(for: photo) == recipe)
    }
}

@Suite("Save over original")
struct OverwriteTests {
    @Test func keepsBackupAndWritesEdits() throws {
        let dir = try makeTempDirectory()
        let photo = dir.appendingPathComponent("beach.jpg")
        try writePhoto(Grid.numbered(width: 4, height: 2), to: photo)
        let originalData = try Data(contentsOf: photo)
        let recipe = EditRecipe().rotated(clockwise: true)

        let backup = try OriginalOverwriter.overwrite(photo: photo, recipe: recipe, engine: testEngine,
                                                      backupDirectory: dir.appendingPathComponent("Backups"))
        #expect(try Data(contentsOf: backup) == originalData)
        #expect(try ImageLoader.info(for: photo).pixelSize == PixelSize(width: 2, height: 4))

        // A second backup on the same day gets its own name.
        let second = try OriginalOverwriter.overwrite(photo: photo, recipe: EditRecipe(), engine: testEngine,
                                                      backupDirectory: dir.appendingPathComponent("Backups"))
        #expect(second.lastPathComponent == "beach 2.jpg")
    }

    @Test func refusesFormatsItCannotWrite() throws {
        let dir = try makeTempDirectory()
        let photo = dir.appendingPathComponent("anim.gif")
        try writePhoto(Grid.numbered(width: 2, height: 2), to: photo, type: .gif)
        #expect(throws: FotolarkError.self) {
            try OriginalOverwriter.overwrite(photo: photo, recipe: EditRecipe().rotated(clockwise: true),
                                             engine: testEngine, backupDirectory: dir)
        }
        // Nothing was backed up or touched.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Backups").path))
    }
}
