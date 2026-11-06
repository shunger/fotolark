import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FotolarkKit

@Suite("Bulk metadata, auto-fix, video import")
struct Batch6Tests {
    func photo(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("meta.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, Grid.numbered(width: 5, height: 4).cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:07:04 10:30:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.6, kCGImagePropertyGPSLatitudeRef: "N"],
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
        return url
    }

    @Test func shiftsDateAddsKeywordsRemovesLocationWithoutTouchingPixels() throws {
        let dir = try makeTempDirectory()
        let url = try photo(in: dir)
        let pixelsBefore = readGrid(try ImageLoader.loadFull(url))
        var changes = MetadataChanges()
        changes.shiftSeconds = 3600 + 30
        changes.addKeywords = ["Beach", "Family"]
        changes.removeLocation = true
        let undo = try MetadataEditor.apply(changes, to: url, backupDirectory: dir.appendingPathComponent("Backups"))

        let props = properties(url)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:07:04 11:30:30")
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["Beach", "Family"])
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect(readGrid(try ImageLoader.loadFull(url)) == pixelsBefore, "pixels not re-encoded")

        #expect(BulkRunner.undo(undo, store: RecipeStore(fallbackDirectory: dir)).isEmpty)
        let restored = properties(url)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(restored?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:07:04 10:30:00")
        #expect(properties(url)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func keywordsAreNotDuplicated() throws {
        let dir = try makeTempDirectory()
        let url = try photo(in: dir)
        var c = MetadataChanges()
        c.addKeywords = ["Beach"]
        _ = try MetadataEditor.apply(c, to: url, backupDirectory: dir)
        c.addKeywords = ["beach", "Sunset"]
        _ = try MetadataEditor.apply(c, to: url, backupDirectory: dir)
        let iptc = properties(url)[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["Beach", "Sunset"])
    }

    @Test func bulkMagicFixIsUndoable() throws {
        let dir = try makeTempDirectory()
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent(".fb"))
        let p = try makePhotos(["fix.jpg"], in: dir)[0]
        let steps = try BulkTools.applyEdits(EditRecipe().setting(.magicFix(FilterChain(steps: [FilterStep(name: "x", parameters: [:])]))),
                                             to: p, store: store, engine: testEngine)
        #expect(store.load(for: p)?.operation(.magicFix) != nil)
        _ = BulkRunner.undo(steps, store: store)
        #expect(store.load(for: p) == nil)
    }

    @Test func livePhotoClipsAndVideos() {
        func c(_ name: String) -> ImportCandidate {
            ImportCandidate(id: name, name: name, fileSize: 1, date: nil, typeIdentifier: nil)
        }
        let all = [c("IMG_1.HEIC"), c("IMG_1.MOV"), c("IMG_2.JPG"), c("IMG_3.MOV")]
        var o = ImportOptions()
        var plan = Importer.plan(all, options: o)
        #expect(plan.shown.map(\.name) == ["IMG_1.HEIC", "IMG_2.JPG"] && plan.clips.isEmpty)
        o.includeLiveClips = true
        o.includeVideos = true
        plan = Importer.plan(all, options: o)
        #expect(plan.shown.map(\.name) == ["IMG_1.HEIC", "IMG_2.JPG", "IMG_3.MOV"])
        #expect(plan.clips["IMG_1.HEIC"]?.name == "IMG_1.MOV")
    }

    @Test func videosAreCopiedAsIs() throws {
        let dir = try makeTempDirectory()
        let tmp = dir.appendingPathComponent("dl.tmp")
        try Data(repeating: 7, count: 1000).write(to: tmp)
        let c = ImportCandidate(id: "v", name: "IMG_3.MOV", fileSize: 1000, date: nil, typeIdentifier: nil)
        var o = ImportOptions()
        o.convertHEICToJPEG = true
        let placed = try Importer.place(tmp, candidate: c, index: 0, options: o, root: dir.appendingPathComponent("out"), engine: testEngine)
        #expect(placed.files.map(\.lastPathComponent) == ["IMG_3.MOV"] && placed.verified)
    }
}
