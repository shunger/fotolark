import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Retouching")
struct RetouchTests {
    /// Smooth skin-like gradient with a dark blemish at the middle.
    func skinWithBlemish() -> (photo: CIImage, clean: CIImage) {
        let f = CIFilter(name: "CILinearGradient")!
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        f.setValue(CIVector(x: 300, y: 0), forKey: "inputPoint1")
        f.setValue(CIColor(red: 0.85, green: 0.65, blue: 0.55), forKey: "inputColor0")
        f.setValue(CIColor(red: 0.75, green: 0.55, blue: 0.45), forKey: "inputColor1")
        let clean = f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        let spot = solid(r: 0.3, g: 0.15, b: 0.1, width: 10, height: 10).transformed(by: CGAffineTransform(translationX: 145, y: 95))
        return (spot.composited(over: clean), clean)
    }

    func difference(_ a: CIImage, _ b: CIImage, around: (x: Int, y: Int), r: Int) -> Double {
        let ga = readGrid(a), gb = readGrid(b)
        var worst = 0.0
        for y in (around.y - r)...(around.y + r) {
            for x in (around.x - r)...(around.x + r) {
                for c in 0..<3 { worst = max(worst, abs(Double(ga[x, y][c]) - Double(gb[x, y][c]))) }
            }
        }
        return worst
    }

    @Test func spotHealRemovesBlemishAndBlendsIn() {
        let (photo, clean) = skinWithBlemish()
        let radius = 12.0 / 300
        let offset = testEngine.healSourceOffset(for: CGPoint(x: 0.5, y: 0.5), radius: radius, in: photo)
        #expect(abs(offset.x) + abs(offset.y) > 0, "picked a nearby source")
        let stroke = RetouchStroke(tool: .heal, points: [CurvePoint(0.5, 0.5)], radius: radius, sourceOffset: offset)
        let healed = RecipeRenderer.apply(EditRecipe().setting(.retouch([stroke])), to: photo)
        let before = difference(photo, clean, around: (150, 100), r: 4)
        let after = difference(healed, clean, around: (150, 100), r: 4)
        #expect(before > 100)
        #expect(after < 6, "healed area matches clean skin within \(after) levels")
        // A plain copy from the source spot would carry that spot's (different) shading.
        let cloned = RecipeRenderer.apply(EditRecipe().setting(.retouch([RetouchStroke(tool: .clone, points: [CurvePoint(0.5, 0.5)],
                                                                                          radius: radius, sourceOffset: CurvePoint(0.25, 0))])), to: photo)
        #expect(difference(cloned, clean, around: (150, 100), r: 4) > after + 3, "healing matches light better than cloning")
        // Far away is untouched.
        #expect(difference(healed, photo, around: (40, 40), r: 3) <= 1)
    }

    @Test func cloneCopiesExactPixels() {
        let grid = Grid.numbered(width: 5, height: 4)
        // Copy from one pixel to the right.
        let stroke = RetouchStroke(tool: .clone, points: [CurvePoint(0.3, 0.375)], radius: 0.3,
                                   sourceOffset: CurvePoint(0.2, 0))
        let out = readGrid(RecipeRenderer.apply(EditRecipe().setting(.retouch([stroke])), to: grid.ciImage))
        #expect(close(Grid(width: 1, height: 1, pixels: [out[1, 1]]), Grid(width: 1, height: 1, pixels: [grid[2, 1]]), tolerance: 3))
    }

    @Test func softenSmoothsOnlyWherePainted() {
        let noise = Phase3ToneTests().noisy()
        let stroke = RetouchStroke(tool: .soften, points: [CurvePoint(0.2, 0.5), CurvePoint(0.4, 0.5)], radius: 0.1, strength: 1)
        let out = readGrid(RecipeRenderer.apply(EditRecipe().setting(.retouch([stroke])), to: noise))
        let orig = readGrid(noise)
        func spread(_ g: Grid, _ xs: Range<Int>) -> Double {
            // Rows 70–79 run through the middle of the stroke (y = 0.5 of 150 px).
            let v = xs.flatMap { x in (70..<80).map { y in Double(g[x, y][1]) } }
            let m = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        #expect(spread(out, 50..<70) < spread(orig, 50..<70) * 0.6, "painted area smoother: \(spread(orig, 50..<70)) → \(spread(out, 50..<70))")
        #expect(abs(spread(out, 150..<170) - spread(orig, 150..<170)) < 0.5, "unpainted area unchanged")
    }

    @Test func strokesRoundTrip() throws {
        let s = RetouchStroke(tool: .clone, points: [CurvePoint(0.1, 0.2), CurvePoint(0.3, 0.4)], radius: 0.02,
                              sourceOffset: CurvePoint(0.05, -0.02))
        let r = EditRecipe().setting(.retouch([s]))
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(r)) == r)
        #expect(r.pastableEdits.isEmpty, "retouching belongs to one photo and isn't pasted")
    }
}
