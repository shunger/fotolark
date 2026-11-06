import Foundation
import Testing
@testable import FotolarkKit

@Suite("Quick actions and watch folders")
struct QuickActionTests {
    @Test func resizeConvertAndFix() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("big.jpg")
        var g = Grid(width: 200, height: 100, pixels: [])
        for _ in 0..<100 { for x in 0..<200 { g.pixels.append([UInt8(60 + x / 4), 70, 80, 255]) } }
        try writePhoto(g, to: url)

        let resized = try QuickActions.run(.resize(longestSide: 50), on: url, engine: testEngine)
        #expect(resized.name == "big 50px.jpg")
        let rURL = dir.appendingPathComponent(resized.name)
        try resized.data.write(to: rURL)
        #expect(try ImageLoader.info(for: rURL).pixelSize == PixelSize(width: 50, height: 25))

        let png = try QuickActions.run(.convert(.png), on: url, engine: testEngine)
        #expect(png.name == "big.png")
        #expect(png.data.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        let fixed = try QuickActions.run(.autoFix, on: url, engine: testEngine)
        #expect(fixed.name == "big fixed.jpg")
        #expect(!fixed.data.isEmpty)
        #expect(FileManager.default.contents(atPath: url.path)! == (try Data(contentsOf: url)), "original untouched")
    }

    @Test func watchFolderWaitsForCopiesAndHandlesEachOnce() throws {
        let dir = try makeTempDirectory()
        let a = dir.appendingPathComponent("a.jpg")
        try writePhoto(Grid(width: 64, height: 32, pixels: Array(repeating: [90, 120, 150, 255], count: 64 * 32)), to: a)
        let rule = WatchFolderRule(path: dir.path, bookmark: nil, action: .resize(longestSide: 20))

        // First look: size not seen before, so it might still be copying.
        #expect(WatchFolderProcessor.pending(in: dir, handled: [], previousSizes: [:]).isEmpty)
        let sizes = Dictionary(uniqueKeysWithValues: PhotoScanner.photos(in: dir).map { ($0.name, $0.fileSize) })
        let ready = WatchFolderProcessor.pending(in: dir, handled: [], previousSizes: sizes)
        #expect(ready.map(\.name) == ["a.jpg"])

        let out = try WatchFolderProcessor.process(a, rule: rule, in: dir, engine: testEngine)
        #expect(out.deletingLastPathComponent().lastPathComponent == "Fotolark")
        #expect(try ImageLoader.info(for: out).pixelSize.width == 20)
        let handled = Set(ready.map(WatchFolderProcessor.handledKey))
        #expect(WatchFolderProcessor.pending(in: dir, handled: handled, previousSizes: sizes).isEmpty)
        // Results land in a subfolder, so they're never picked up again.
        #expect(PhotoScanner.photos(in: dir).map(\.name) == ["a.jpg"])
    }
}
