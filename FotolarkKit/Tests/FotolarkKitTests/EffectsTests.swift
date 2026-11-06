import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Looks, text and watermarks")
struct EffectsTests {
    let color = solid(r: 0.8, g: 0.4, b: 0.2, width: 300, height: 200)

    @Test(arguments: Look.Kind.allCases)
    func everyLookChangesThePhotoAndStaysStable(kind: Look.Kind) {
        // A photo with detail (soft focus and glow leave a flat color alone, as they should).
        let detailed = Grid.numbered(width: 5, height: 4).ciImage
            .transformed(by: CGAffineTransform(scaleX: 60, y: 50)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        let recipe = EditRecipe().setting(.looks([Look(kind: kind)]))
        let a = readGrid(RecipeRenderer.apply(recipe, to: detailed))
        let b = readGrid(RecipeRenderer.apply(recipe, to: detailed))
        #expect(a == b, "\(kind) renders the same every time (film grain included)")
        #expect(a != readGrid(detailed), "\(kind) does something")
        #expect(a.width == 300 && a.height == 200)
    }

    @Test func filmGrainAddsTextureToFlatAreas() {
        let flat = solid(r: 0.5, g: 0.5, b: 0.5, width: 300, height: 200)
        let g = readGrid(RecipeRenderer.apply(EditRecipe().setting(.looks([Look(kind: .filmGrain)])), to: flat))
        let v = g.pixels.map { Double($0[1]) }
        let m = v.reduce(0, +) / Double(v.count)
        let spread = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        #expect(spread > 3, "grain spread \(spread)")
        #expect(abs(m - Double(readGrid(flat)[0, 0][1])) < 4, "brightness about the same: \(m)")
    }

    @Test func strengthBlends() {
        let half = averageColor(RecipeRenderer.apply(EditRecipe().setting(.looks([Look(kind: .blackAndWhite, strength: 0.5)])), to: color))
        let full = averageColor(RecipeRenderer.apply(EditRecipe().setting(.looks([Look(kind: .blackAndWhite)])), to: color))
        let none = averageColor(color)
        #expect(abs(full.r - full.b) < 3)
        #expect(half.r - half.b > 20 && half.r - half.b < none.r - none.b - 20, "halfway: \(half)")
    }

    @Test func focalBWKeepsColorAtTheFocus() {
        let look = Look(kind: .focalBW, focusX: 0.25, focusY: 0.5, focusRadius: 0.12)
        let g = readGrid(RecipeRenderer.apply(EditRecipe().setting(.looks([look])), to: color))
        let atFocus = g[75, 100], far = g[260, 100]
        #expect(Int(atFocus[0]) - Int(atFocus[2]) > 100, "color kept at focus: \(atFocus)")
        #expect(abs(Int(far[0]) - Int(far[2])) < 4, "gray elsewhere: \(far)")
    }

    @Test func textIsDrawnWhereAsked() {
        let gray = solid(r: 0.2, g: 0.2, b: 0.2, width: 400, height: 300)
        let overlay = TextOverlay(text: "HELLO", size: 0.15, color: .white, x: 0.5, y: 0.25, shadow: false)
        let g = readGrid(RecipeRenderer.apply(EditRecipe().setting(.text([overlay])), to: gray))
        func bright(_ ys: Range<Int>) -> Int { ys.reduce(0) { n, y in n + (0..<400).filter { g[$0, y][1] > 200 }.count } }
        #expect(bright(50..<100) > 200, "text in the top part")
        #expect(bright(200..<300) == 0, "nothing at the bottom")
    }

    @Test func textStaysPutWhenCropping() {
        let r = EditRecipe().setting(.crop(CropRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
            .setting(.text([TextOverlay(text: "A")]))
        #expect(r.operations.map(\.kind) == [.crop, .text], "text comes after the crop")
    }

    @Test func watermarkGoesInTheCornerOnExport() throws {
        let dir = try makeTempDirectory()
        let src = try makePhotos(["w.jpg"], in: dir, size: (400, 300))[0]
        let data = try ImageExporter.encode(source: src, recipe: EditRecipe(), options: ExportOptions(
            format: .png, watermark: Watermark(text: "© Test", position: .bottomRight, size: 0.08, opacity: 1)), engine: testEngine)
        let cg = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        let g = readGrid(cg)
        func whites(_ xs: Range<Int>, _ ys: Range<Int>) -> Int { xs.reduce(0) { n, x in n + ys.filter { g[x, $0][1] > 220 }.count } }
        #expect(whites(250..<400, 230..<300) > 50, "mark at bottom right")
        #expect(whites(0..<150, 0..<70) == 0, "nothing at top left")
    }

    @Test func presetKeepsOnlyPastableEdits() throws {
        let recipe = EditRecipe().rotated(clockwise: true).setting(.looks([Look(kind: .sepia)]))
            .settingAdjustments({ var a = Adjustments(); a.contrast = 0.3; return a }())
        let preset = EditPreset(name: "Old times", recipe: recipe)
        #expect(preset.recipe.operation(.orient) == nil && preset.recipe.looks.count == 1)
        #expect(try JSONDecoder().decode(EditPreset.self, from: JSONEncoder().encode(preset)) == preset)
    }
}
