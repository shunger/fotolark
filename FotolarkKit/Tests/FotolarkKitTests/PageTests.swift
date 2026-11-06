import CoreGraphics
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Print, contact sheet, PDF and collage layouts")
struct PageTests {
    func settings(_ size: PrintSize, paper: PaperSize = .letter) -> PageSettings {
        var s = PageSettings()
        s.paper = paper
        s.printSize = size
        return s
    }

    @Test func standardSizesFitAsManyAsPossible() {
        #expect(PageLayout.printCells(settings(.size4x6)).count == 2)
        #expect(PageLayout.printCells(settings(.wallet)).count == 9)
        #expect(PageLayout.printCells(settings(.size8x10)).count == 1)
        #expect(PageLayout.printCells(settings(.size5x7)).count == 2, "two fit sideways on letter")
        let full = PageLayout.printCells(settings(.fullPage))
        #expect(full == [CGRect(x: 18, y: 18, width: 576, height: 756)])
        // Every cell is the print size and on the page.
        for cell in PageLayout.printCells(settings(.wallet)) {
            #expect(cell.size == CGSize(width: 180, height: 252))
            #expect(CGRect(x: 0, y: 0, width: 612, height: 792).contains(cell))
        }
        // A print too big for the paper still gets the whole page.
        #expect(PageLayout.printCells(settings(.size8x10, paper: .photo4x6)).count == 1)
    }

    @Test func photosGoOntoPagesInOrderOrRepeated() {
        var s = settings(.size4x6)
        #expect(PDFComposer.pages(count: 5, kind: .prints, settings: s) == [[0, 1], [2, 3], [4]])
        s.repeatEach = true
        #expect(PDFComposer.pages(count: 2, kind: .prints, settings: s) == [[0, 0], [1, 1]])
    }

    @Test func fitKeepsTheShapeAndTurnsWhenThatHelps() {
        let cell = CGRect(x: 0, y: 0, width: 200, height: 300)
        let upright = PageLayout.place(aspect: 1.5, in: cell, fill: false, autoRotate: false)
        #expect(!upright.turned)
        #expect(abs(upright.rect.width / upright.rect.height - 1.5) < 0.01)
        #expect(cell.contains(upright.rect))
        let turned = PageLayout.place(aspect: 1.5, in: cell, fill: false, autoRotate: true)
        #expect(turned.turned)
        #expect(turned.rect.height > upright.rect.height, "sideways prints bigger")
        #expect(PageLayout.place(aspect: 1.5, in: cell, fill: true, autoRotate: false).rect == cell)
    }

    @Test func makesPDFPages() throws {
        let dir = try makeTempDirectory()
        var items: [PageItem] = []
        for i in 0..<3 {
            let url = dir.appendingPathComponent("p\(i).jpg")
            try writePhoto(Grid.numbered(width: 6, height: 4), to: url)
            items.append(PageItem(url: url, recipe: EditRecipe()))
        }
        let pdf = try PDFComposer.make(items, kind: .prints, settings: settings(.size4x6), engine: testEngine, dpi: 72)
        let doc = CGPDFDocument(CGDataProvider(data: pdf as CFData)!)!
        #expect(doc.numberOfPages == 2)
        #expect(doc.page(at: 1)?.getBoxRect(.mediaBox).size == CGSize(width: 612, height: 792))

        var contact = settings(.fullPage)
        contact.columns = 4
        let sheet = try PDFComposer.make(items, kind: .contactSheet(title: "Trip"), settings: contact, engine: testEngine, dpi: 72)
        #expect(CGPDFDocument(CGDataProvider(data: sheet as CFData)!)!.numberOfPages == 1)
        #expect(PageLayout.contactCells(contact).count % 4 == 0)

        let preview = try PDFComposer.make(items, kind: .prints, settings: settings(.size4x6), engine: testEngine,
                                           dpi: 30, pageLimit: 1)
        #expect(CGPDFDocument(CGDataProvider(data: preview as CFData)!)!.numberOfPages == 1)
    }

    @Test(arguments: CollageSettings.Layout.allCases)
    func collagePlacesEveryPhotoOnTheCanvas(layout: CollageSettings.Layout) {
        var s = CollageSettings()
        s.layout = layout
        let aspects = [1.5, 0.67, 1.0, 1.5, 1.33, 0.75, 1.5]
        let places = CollageMaker.placements(aspects: aspects, settings: s)
        #expect(places.count == aspects.count)
        let canvas = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        for p in places {
            #expect(canvas.intersects(p.rect))
            if layout != .freeform {
                #expect(canvas.insetBy(dx: -0.5, dy: -0.5).contains(p.rect), "\(p.rect)")
            }
        }
        if layout != .freeform {
            for i in places.indices { for j in places.indices where j > i {
                #expect(places[i].rect.intersection(places[j].rect).width < 0.5, "\(i) and \(j) overlap")
            } }
        }
        if layout == .mosaic {
            // Every photo keeps roughly its own shape.
            for (p, a) in zip(places, aspects) {
                #expect(abs(log(Double(p.rect.width / p.rect.height) / a)) < 0.35, "\(p.rect) vs \(a)")
            }
        }
        if layout == .freeform {
            var other = s
            other.seed = 2
            #expect(CollageMaker.placements(aspects: aspects, settings: s) == places, "same seed, same layout")
            #expect(CollageMaker.placements(aspects: aspects, settings: other) != places)
        }
    }

    @Test func collageRendersAtTheChosenSize() throws {
        let dir = try makeTempDirectory()
        var items: [PageItem] = []
        for i in 0..<4 {
            let url = dir.appendingPathComponent("c\(i).jpg")
            try writePhoto(Grid.numbered(width: 6, height: 4), to: url)
            items.append(PageItem(url: url, recipe: EditRecipe()))
        }
        var s = CollageSettings()
        s.size = PixelSize(width: 300, height: 200)
        s.background = .black
        let image = try #require(CollageMaker.render(items, settings: s, engine: testEngine))
        #expect(image.extent == CGRect(x: 0, y: 0, width: 300, height: 200))
        let g = readGrid(image)
        #expect(g[0, 0] == [0, 0, 0, 255], "background shows in the gaps")
        #expect(g[75, 50] != [0, 0, 0, 255], "a photo is there")
    }
}
