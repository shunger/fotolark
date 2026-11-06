import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FotolarkKit

@Suite("Library index and search")
struct SearchTests {
    func jpeg(_ name: String, in dir: URL, date: String? = nil, model: String? = nil, keywords: [String] = [],
              image: CGImage = Grid.numbered(width: 4, height: 3).cgImage) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let date { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
        if let model { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: model] }
        if !keywords.isEmpty { props[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCKeywords: keywords] }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// Black words on white, large enough to read.
    func textImage(_ text: String) -> CGImage {
        let w = 900, h = 260
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 90, nil)
        let attr = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        ctx.textPosition = CGPoint(x: 40, y: 90)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        return ctx.makeImage()!
    }

    @Test func indexesFindsAndForgets() throws {
        let dir = try makeTempDirectory()
        let trip = dir.appendingPathComponent("Paris Trip")
        try FileManager.default.createDirectory(at: trip, withIntermediateDirectories: true)
        let a = try jpeg("tower.jpg", in: trip, date: "2024:07:14 10:00:00", model: "Z50", keywords: ["Landmark"])
        let b = try jpeg("dog.jpg", in: dir, date: "2023:01:02 09:00:00")
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library"))
        try store.saveLabels(PhotoLabels(rating: 4, tags: ["Rex"]), for: b)

        let index = LibraryIndex(fileURL: dir.appendingPathComponent("Index.json"))
        #expect(index.refresh(roots: [dir], store: store))
        #expect(index.count == 2)
        func names(_ q: String) -> [String] { index.search(q).map(\.name) }
        #expect(names("tower") == ["tower.jpg"])
        #expect(names("paris") == ["tower.jpg"], "folder name")
        #expect(names("landmark") == ["tower.jpg"], "keyword in the file")
        #expect(names("z50") == ["tower.jpg"], "camera")
        #expect(names("rex") == ["dog.jpg"], "tag")
        #expect(names("2024") == ["tower.jpg"])
        #expect(names("July") == ["tower.jpg"])
        #expect(names("jan 2023") == ["dog.jpg"])
        #expect(names("tower 2023").isEmpty, "every word must match")
        #expect(names("\"paris trip\"") == ["tower.jpg"])
        #expect(index.all.map(\.name) == ["tower.jpg", "dog.jpg"], "newest first")
        #expect(index.entry(for: b)?.labels.rating == 4)

        // Saved and reloaded; a second pass with nothing new changes nothing.
        let again = LibraryIndex(fileURL: dir.appendingPathComponent("Index.json"))
        #expect(again.count == 2)
        #expect(!again.refresh(roots: [dir], store: store))

        index.updateLabels(PhotoLabels(tags: ["Buddy"]), for: b)
        #expect(names("buddy") == ["dog.jpg"])

        try FileManager.default.removeItem(at: a)
        #expect(index.refresh(roots: [dir], store: store))
        #expect(names("tower").isEmpty)
        // Photos outside the watched folders are dropped too.
        #expect(index.refresh(roots: [], store: store))
        #expect(index.count == 0)
    }

    @Test func readsTextInPhotosAndSearchesIt() throws {
        let dir = try makeTempDirectory()
        let sign = try jpeg("sign.jpg", in: dir, image: textImage("BAKERY OPEN"))
        _ = try jpeg("plain.jpg", in: dir)
        let index = LibraryIndex(fileURL: dir.appendingPathComponent("Index.json"))
        index.refresh(roots: [dir], store: RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library")))
        #expect(index.photosNeedingText().count == 2)
        for url in index.photosNeedingText() { index.setText(LibraryIndex.recognizeText(in: url), for: url) }
        #expect(index.photosNeedingText().isEmpty)
        #expect(index.search("bakery").map(\.name) == ["sign.jpg"])
        #expect(index.entry(for: sign)?.text?.localizedCaseInsensitiveContains("open") == true)
    }
}
