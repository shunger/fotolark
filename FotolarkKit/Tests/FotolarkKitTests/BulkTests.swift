import CoreImage
import Foundation
import ImageIO
import Testing
@testable import FotolarkKit

func makePhotos(_ names: [String], in dir: URL, size: (Int, Int) = (40, 30)) throws -> [URL] {
    let cg = testEngine.makeCGImage(solid(r: 0.3, g: 0.5, b: 0.7, width: size.0, height: size.1))!
    return try names.map { name in
        let url = dir.appendingPathComponent(name)
        try writePhoto(readGrid(cg), to: url, dateTaken: "2026:07:04 10:30:00")
        return url
    }
}

func properties(_ url: URL) -> [CFString: Any] {
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
}

@Suite("Export options")
struct ExportOptionTests {
    func photoWithLocation(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("gps.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, Grid.numbered(width: 4, height: 3).cgImage, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:07:04 10:30:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    @Test(arguments: MetadataPolicy.allCases)
    func metadataPolicy(policy: MetadataPolicy) throws {
        let dir = try makeTempDirectory()
        let src = try photoWithLocation(in: dir)
        let out = dir.appendingPathComponent("out-\(policy.rawValue).jpg")
        try ImageExporter.export(source: src, recipe: EditRecipe(), options: ExportOptions(metadata: policy),
                                 to: out, engine: testEngine)
        let props = properties(out)
        let hasGPS = props[kCGImagePropertyGPSDictionary] != nil
        let date = (props[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal]
        switch policy {
        case .keepAll: #expect(hasGPS && date != nil)
        case .removeLocation: #expect(!hasGPS && date != nil)
        case .removeAll: #expect(!hasGPS && date == nil)
        }
    }

    @Test func maxLongestSideShrinksButNeverEnlarges() throws {
        let dir = try makeTempDirectory()
        let src = try makePhotos(["big.jpg"], in: dir, size: (400, 300))[0]
        let small = try ImageExporter.encode(source: src, recipe: EditRecipe(),
                                             options: ExportOptions(maxLongestSide: 100), engine: testEngine)
        let big = try ImageExporter.encode(source: src, recipe: EditRecipe(),
                                           options: ExportOptions(maxLongestSide: 4000), engine: testEngine)
        func size(_ d: Data) -> (Int, Int) {
            let p = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(d as CFData, nil)!, 0, nil) as! [CFString: Any]
            return (p[kCGImagePropertyPixelWidth] as! Int, p[kCGImagePropertyPixelHeight] as! Int)
        }
        #expect(size(small) == (100, 75))
        #expect(size(big) == (400, 300))
    }

    @Test func presetsRoundTripAndOldOptionsDecode() throws {
        let data = try JSONEncoder().encode(ExportPreset.builtIn)
        #expect(try JSONDecoder().decode([ExportPreset].self, from: data) == ExportPreset.builtIn)
        let old = #"{"format":"png","quality":0.5,"colorSpace":"sRGB"}"#
        let o = try JSONDecoder().decode(ExportOptions.self, from: Data(old.utf8))
        #expect(o.format == .png && o.metadata == .keepAll && o.maxLongestSide == nil)
    }
}

@Suite("Bulk jobs")
struct BulkJobTests {
    @Test func runnerSkipsFailuresAndUndoRemovesCreatedFiles() async throws {
        let dir = try makeTempDirectory()
        let photos = try makePhotos(["a.jpg", "b.jpg", "c.jpg"], in: dir) + [dir.appendingPathComponent("missing.jpg")]
        let out = dir.appendingPathComponent("out")
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent(".fb"))
        let result = await BulkRunner.run(photos, name: { $0.lastPathComponent }, control: JobControl(),
                                          progress: { _ in }) { url in
            try BulkTools.exportCopy(of: url, recipe: EditRecipe(), options: ExportOptions(format: .png), to: out,
                                     engine: testEngine)
        }
        #expect(result.completed == 4)
        #expect(result.skipped.map(\.name) == ["missing.jpg"])
        let made = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(made == ["a.png", "b.png", "c.png"])
        #expect(BulkRunner.undo(result.undo, store: store).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
    }

    @Test func cancelStopsStartingNewItems() async throws {
        let control = JobControl()
        control.cancel()
        let result = await BulkRunner.run(Array(0..<50), name: { "\($0)" }, control: control, progress: { _ in }) { _ in [] }
        #expect(result.completed == 0 && result.wasCancelled)
    }

    @Test func resizeByPercentAndLongestSide() async throws {
        let dir = try makeTempDirectory()
        let src = try makePhotos(["p.jpg"], in: dir, size: (400, 200))[0]
        let out = dir.appendingPathComponent("r")
        _ = try BulkTools.resizedCopy(of: src, recipe: EditRecipe(), rule: .percent(50), allowEnlarging: false,
                                      options: ExportOptions(), to: out, engine: testEngine)
        _ = try BulkTools.resizedCopy(of: src, recipe: EditRecipe(), rule: .longestSide(1000), allowEnlarging: false,
                                      options: ExportOptions(), to: out, engine: testEngine)
        let sizes = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .map { try ImageLoader.info(for: $0).pixelSize.width }
        #expect(Set(sizes) == [200, 400], "50% → 200 wide; 1000 px longest side doesn't enlarge → 400")
    }

    @Test func rotateIsUndoable() throws {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent(".fb"))
        let p = try makePhotos(["r.jpg"], in: dir)[0]
        let steps = try BulkTools.rotate(p, clockwise: true, store: store)
        #expect(store.load(for: p)?.orientation.quarterTurns == 1)
        _ = BulkRunner.undo(steps, store: store)
        #expect(store.load(for: p) == nil)
    }

    @Test func moveIntoDateFoldersAndBack() throws {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent(".fb"))
        let p = try makePhotos(["m.jpg"], in: dir)[0]
        try store.save(EditRecipe().rotated(clockwise: true), for: p)
        let date = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        let dest = dir.appendingPathComponent("Pictures")
        let steps = try BulkTools.transfer(p, copy: false, to: dest,
                                           dateFolders: DateFolderPattern(style: .yearThenDay, eventName: "Beach"),
                                           dateTaken: date, store: store)
        let moved = dest.appendingPathComponent("2026/2026-11-06 Beach/m.jpg")
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(store.load(for: moved)?.orientation.quarterTurns == 1)
        #expect(BulkRunner.undo(steps, store: store).isEmpty)
        #expect(FileManager.default.fileExists(atPath: p.path))
        #expect(store.load(for: p)?.orientation.quarterTurns == 1)
    }
}

@Suite("Bulk rename")
struct RenameTests {
    @Test func patternTokensAndNumbering() throws {
        let dir = try makeTempDirectory()
        let photos = try makePhotos(["IMG_1.JPG", "IMG_2.JPG"], in: dir)
        var rule = RenameRule()
        rule.pattern = "Beach-{date}-{number}"
        rule.digits = 2
        rule.lowercaseExtension = true
        let date = ISO8601DateFormatter().date(from: "2026-07-04T10:30:00Z")!
        let local = DateFormatter(); local.dateFormat = "yyyy-MM-dd"
        let items = RenamePlan.preview(rule, photos: photos, dates: [photos[0]: date, photos[1]: date])
        #expect(items.map(\.newName) == ["Beach-\(local.string(from: date))-01.jpg", "Beach-\(local.string(from: date))-02.jpg"])
        #expect(items.allSatisfy { $0.problem == nil })
    }

    @Test func findReplaceAndCase() throws {
        let dir = try makeTempDirectory()
        let photos = try makePhotos(["DSC Holiday.jpg"], in: dir)
        var rule = RenameRule()
        rule.mode = .findReplace
        rule.find = "dsc "
        rule.replace = ""
        #expect(RenamePlan.preview(rule, photos: photos, dates: [:])[0].newName == "Holiday.jpg")
        rule.mode = .changeCase
        rule.textCase = .upper
        #expect(RenamePlan.preview(rule, photos: photos, dates: [:])[0].newName == "DSC HOLIDAY.jpg")
    }

    @Test func clashesAreFlagged() throws {
        let dir = try makeTempDirectory()
        let photos = try makePhotos(["a.jpg", "b.jpg"], in: dir)
        _ = try makePhotos(["taken.jpg"], in: dir)
        var rule = RenameRule()
        rule.pattern = "same"
        #expect(RenamePlan.preview(rule, photos: photos, dates: [:]).allSatisfy { $0.problem != nil })
        rule.pattern = "taken"
        #expect(RenamePlan.preview(rule, photos: [photos[0]], dates: [:])[0].problem != nil)
    }

    @Test func swappingNamesWorksAndUndoes() throws {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent(".fb"))
        let photos = try makePhotos(["one.jpg", "two.jpg"], in: dir)
        let r1 = EditRecipe().rotated(clockwise: true)
        try store.save(r1, for: photos[0])
        // Swap: one → two, two → one.
        let items = [RenamePreviewItem(source: photos[0], newName: "two.jpg", problem: nil),
                     RenamePreviewItem(source: photos[1], newName: "one.jpg", problem: nil)]
        let result = RenamePlan.apply(items, store: store)
        #expect(result.skipped.isEmpty && result.completed == 2)
        #expect(store.load(for: photos[1]) == r1, "edits followed the photo to its new name")
        #expect(store.load(for: photos[0]) == nil)
        #expect(BulkRunner.undo(result.undo, store: store).isEmpty)
        #expect(store.load(for: photos[0]) == r1)
    }
}
