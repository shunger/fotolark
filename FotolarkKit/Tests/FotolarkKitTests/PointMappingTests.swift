import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Point mapping")
struct PointMappingTests {
    /// A black image with one white dot at `dot` (normalized, top-left origin).
    func dotImage(width: Int, height: Int, dot: CGPoint) -> CIImage {
        let black = solid(r: 0, g: 0, b: 0, width: width, height: height)
        let px = CGRect(x: (dot.x * Double(width)).rounded(.down) - 2, y: Double(height) - (dot.y * Double(height)).rounded(.down) - 3,
                        width: 5, height: 5)
        return solid(r: 1, g: 1, b: 1, width: width, height: height).cropped(to: px).composited(over: black)
    }

    /// Where the bright dot ends up after rendering, normalized.
    func findDot(_ image: CIImage) -> CGPoint {
        let g = readGrid(image)
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<g.height { for x in 0..<g.width where g[x, y][1] > 128 { sx += Double(x); sy += Double(y); n += 1 } }
        return CGPoint(x: (sx / n + 0.5) / Double(g.width), y: (sy / n + 0.5) / Double(g.height))
    }

    static let recipes: [EditRecipe] = [
        EditRecipe(),
        EditRecipe().rotated(clockwise: true),
        EditRecipe().flipped(horizontally: true).rotated(clockwise: false),
        EditRecipe().setting(.straighten(degrees: 8)),
        EditRecipe().setting(.straighten(degrees: -15)).setting(.crop(CropRect(x: 0.1, y: 0.15, width: 0.7, height: 0.6))),
        EditRecipe().rotated(clockwise: true).setting(.straighten(degrees: 5)).setting(.crop(CropRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8))),
    ]

    @Test(arguments: 0..<recipes.count)
    func mappingMatchesRenderedPixels(index: Int) throws {
        let recipe = Self.recipes[index]
        let size = PixelSize(width: 300, height: 200)
        let dot = CGPoint(x: 0.55, y: 0.45)
        let rendered = RecipeRenderer.apply(recipe, to: dotImage(width: 300, height: 200, dot: dot))
        let found = findDot(rendered)
        let predicted = try #require(PointMapping.displayPoint(fromSource: dot, recipe: recipe, sourceSize: size))
        #expect(abs(found.x - predicted.x) < 0.02 && abs(found.y - predicted.y) < 0.02,
                "recipe \(index): rendered \(found), predicted \(predicted)")
        let back = PointMapping.sourcePoint(fromDisplay: predicted, recipe: recipe, sourceSize: size)
        #expect(abs(back.x - dot.x) < 1e-6 && abs(back.y - dot.y) < 1e-6, "round trip \(back)")
    }

    @Test func croppedAwayPointsAreNil() {
        let recipe = EditRecipe().setting(.crop(CropRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        #expect(PointMapping.displayPoint(fromSource: CGPoint(x: 0.2, y: 0.5), recipe: recipe,
                                          sourceSize: PixelSize(width: 100, height: 100)) == nil)
    }
}
