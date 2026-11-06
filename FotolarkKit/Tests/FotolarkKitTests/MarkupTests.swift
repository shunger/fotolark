import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FotolarkKit

@Suite("Borders, shapes and versions")
struct MarkupTests {
    let photo = solid(r: 0.1, g: 0.5, b: 0.2, width: 200, height: 100)
    let green: [UInt8] = { readGrid(solid(r: 0.1, g: 0.5, b: 0.2, width: 2, height: 2))[0, 0] }()

    @Test func plainBorderAddsAFrameAllRound() {
        let border = Border(style: .plain, width: 0.1, color: .white)
        let recipe = EditRecipe().setting(.border(border))
        let out = RecipeRenderer.apply(recipe, to: photo)
        #expect(out.extent == CGRect(x: 0, y: 0, width: 220, height: 120))
        #expect(Geometry.outputSize(of: recipe, source: PixelSize(width: 200, height: 100)) == PixelSize(width: 220, height: 120))
        let g = readGrid(out)
        #expect(g[3, 3] == [255, 255, 255, 255])
        #expect(g[216, 116] == [255, 255, 255, 255])
        #expect(g[110, 60] == green)
    }

    @Test func instantPrintHasADeepBottom() {
        let recipe = EditRecipe().setting(.border(Border(style: .polaroid, width: 0.05, color: .white)))
        let out = RecipeRenderer.apply(recipe, to: photo)
        // 5 px sides and top, 20 px bottom.
        #expect(out.extent.size == CGSize(width: 210, height: 125))
        let g = readGrid(out)
        #expect(g[100, 3] == [255, 255, 255, 255], "top")
        #expect(g[100, 115] == [255, 255, 255, 255], "bottom strip")
        #expect(g[100, 50] == green)
    }

    @Test func roundedCornersShowTheBorderColor() {
        let recipe = EditRecipe().setting(.border(Border(style: .rounded, width: 0, color: .black, cornerRadius: 0.2)))
        #expect(!recipe.isEmpty, "rounded corners alone still count")
        let g = readGrid(RecipeRenderer.apply(recipe, to: photo))
        #expect(g[1, 1] == [0, 0, 0, 255], "corner rounded off")
        #expect(g[100, 50] == green)
        #expect(g[100, 1] == green, "edge middle untouched")
    }

    @Test func shapesDrawWhereAsked() {
        let red = RGBAColor(red: 1, green: 0, blue: 0)
        let arrow = MarkupShape(kind: .arrow, start: CurvePoint(0.1, 0.5), end: CurvePoint(0.9, 0.5), color: red, lineWidth: 0.02)
        let box = MarkupShape(kind: .rectangle, start: CurvePoint(0.1, 0.1), end: CurvePoint(0.4, 0.4), color: red, lineWidth: 0.01)
        let g = readGrid(RecipeRenderer.apply(.markup([arrow, box]), to: photo))
        #expect(g[100, 50][0] > 200 && g[100, 50][1] < 60, "arrow shaft")
        #expect(g[178, 50][0] > 200, "arrow head")
        #expect(g[50, 25] == green, "inside the box stays clear")
        #expect(g[20, 25][0] > 200, "box edge")
        let hl = MarkupShape(kind: .highlight, start: CurvePoint(0.6, 0.1), end: CurvePoint(0.9, 0.3),
                             color: RGBAColor(red: 1, green: 1, blue: 0))
        let h = readGrid(RecipeRenderer.apply(.markup([hl]), to: photo))
        #expect(h[150, 20][0] > green[0] + 40 && h[150, 20][1] >= green[1], "tinted but see-through: \(h[150, 20])")
    }

    @Test func versionsAreKeptBesideTheEdits() throws {
        let dir = try makeTempDirectory()
        let url = dir.appendingPathComponent("v.jpg")
        try writePhoto(Grid.numbered(width: 4, height: 3), to: url)
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library"))
        let bw = EditRecipe().setting(.adjust({ var a = Adjustments(); a.saturation = -1; return a }()))
        try store.update(url) { $0.versions.append(EditVersion(name: "Black and white", recipe: bw)) }
        try store.save(EditRecipe().setting(.straighten(degrees: 1)), for: url)
        #expect(store.loadRecord(for: url).versions.map(\.name) == ["Black and white"])
        #expect(store.loadRecord(for: url).versions.first?.recipe == bw)

        let renamed = try PhotoFileOperations(store: store).rename(url, to: "w")
        #expect(store.loadRecord(for: renamed).versions.count == 1)
        try store.update(renamed) { $0.versions = [] }
        try store.save(EditRecipe(), for: renamed)
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: renamed).path))
    }
}
