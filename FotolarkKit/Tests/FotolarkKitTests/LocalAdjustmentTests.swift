import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Lens correction, brushes, gradients, tilt-shift")
struct LocalAdjustmentTests {
    /// Black with white dots at the given pixel positions (top-left origin).
    func dots(_ points: [(Int, Int)], width: Int = 200, height: Int = 150) -> CIImage {
        var g = Grid(width: width, height: height, pixels: Array(repeating: [0, 0, 0, 255], count: width * height))
        for (x, y) in points {
            for dy in -1...1 { for dx in -1...1 { g[x + dx, y + dy] = [255, 255, 255, 255] } }
        }
        return g.ciImage
    }

    /// Brightness-weighted center of a channel.
    func centroid(_ g: Grid, channel: Int = 1, xs: Range<Int>? = nil) -> (x: Double, y: Double) {
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<g.height { for x in xs ?? 0..<g.width {
            let v = Double(g[x, y][channel])
            sx += v * Double(x); sy += v * Double(y); n += v
        } }
        return (sx / max(n, 1), sy / max(n, 1))
    }

    @Test func zeroLensCorrectionIsNoOperation() {
        #expect(EditRecipe().setting(.lens(LensCorrection())).isEmpty)
        let r = EditRecipe().setting(.adjust(Adjustments())).setting(.lens(LensCorrection(distortion: 0.5)))
        #expect(r.operations.first?.kind == .lens, "lens comes before everything")
    }

    @Test func barrelFixPushesEdgesOutward() {
        // A dot up and to the left of center moves further up and left.
        let image = dots([(50, 40)])
        let before = centroid(readGrid(image))
        let fixed = readGrid(RecipeRenderer.apply(.lens(LensCorrection(distortion: 1)), to: image))
        let after = centroid(fixed)
        #expect(after.x < before.x - 1, "moved left: \(before) → \(after)")
        #expect(after.y < before.y - 1, "moved up: \(before) → \(after)")
        // Pincushion fixes keep the corners where they are and spread the middle out.
        let corner = dots([(3, 3)])
        let cornerAfter = centroid(readGrid(RecipeRenderer.apply(.lens(LensCorrection(distortion: -1)), to: corner)))
        #expect(abs(cornerAfter.x - 3) < 1.5 && abs(cornerAfter.y - 3) < 1.5, "corner stays: \(cornerAfter)")
        let spread = centroid(readGrid(RecipeRenderer.apply(.lens(LensCorrection(distortion: -1)), to: image)))
        #expect(spread.x < before.x - 1 && spread.y < before.y - 1, "\(before) → \(spread)")
    }

    @Test func renderingPartOfTheImageMatchesTheWhole() {
        // Core Image renders big images in tiles; each tile must line up with the rest.
        let image = dots([(30, 20), (170, 30), (40, 130), (160, 120), (100, 75)])
        let out = RecipeRenderer.apply(.lens(LensCorrection(distortion: 0.8, chromatic: 0.5)), to: image)
        let whole = readGrid(out)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        for rect in [CGRect(x: 0, y: 0, width: 100, height: 75), CGRect(x: 100, y: 75, width: 100, height: 75),
                     CGRect(x: 120, y: 0, width: 80, height: 40)] {
            let cg = testEngine.context.createCGImage(out, from: rect, format: .RGBA8, colorSpace: space)!
            let part = readGrid(cg)
            // Core Image's y runs up; the grid's runs down.
            let top = whole.height - Int(rect.maxY)
            let expected = whole.cropped(x: Int(rect.minX), y: top, width: Int(rect.width), height: Int(rect.height))
            var worst = 0
            for (a, b) in zip(part.pixels, expected.pixels) {
                for c in 0..<3 { worst = max(worst, abs(Int(a[c]) - Int(b[c]))) }
            }
            #expect(worst <= 2, "tile \(rect) differs by \(worst)")
        }
    }

    @Test func chromaticFixMovesRedAndBlueApart() {
        // A white line near the right edge: red moves toward the center, blue away.
        var g = Grid(width: 200, height: 100, pixels: Array(repeating: [0, 0, 0, 255], count: 200 * 100))
        for y in 0..<100 { g[180, y] = [255, 255, 255, 255] }
        let out = readGrid(RecipeRenderer.apply(.lens(LensCorrection(chromatic: 1)), to: g.ciImage))
        let red = centroid(out, channel: 0, xs: 150..<200).x
        let blue = centroid(out, channel: 2, xs: 150..<200).x
        #expect(red < blue - 0.2, "red \(red), blue \(blue)")
    }

    @Test func brushChangesOnlyWhereItPaintsAndEraserTakesItBack() {
        let image = solid(r: 0.3, g: 0.3, b: 0.3, width: 200, height: 100)
        let stroke = LocalAdjustment.Stroke(points: [CurvePoint(0.1, 0.5), CurvePoint(0.3, 0.5)], radius: 0.1)
        var adj = LocalAdjustment(kind: .brush, strokes: [stroke], settings: .init(exposure: 0.5))
        let out = readGrid(RecipeRenderer.apply(.local([adj]), to: image))
        let base = readGrid(image)[150, 50][1]
        #expect(out[40, 50][1] > base + 20, "painted area brighter")
        #expect(abs(Int(out[170, 50][1]) - Int(base)) <= 1, "rest untouched: \(out[170, 50]) vs \(base)")

        adj.strokes.append(.init(points: [CurvePoint(0.2, 0.5)], radius: 0.1, erase: true))
        let erased = readGrid(RecipeRenderer.apply(.local([adj]), to: image))
        #expect(abs(Int(erased[40, 50][1]) - Int(base)) <= 2, "erased")
        #expect(erased[20, 50][1] > base + 20, "outside the eraser still painted")
    }

    @Test func gradientFadesFromStartToEnd() {
        let image = solid(r: 0.6, g: 0.6, b: 0.6, width: 100, height: 200)
        let sky = LocalAdjustment(kind: .gradient, start: CurvePoint(0.5, 0), end: CurvePoint(0.5, 0.5),
                                  settings: .init(exposure: -0.5))
        let out = readGrid(RecipeRenderer.apply(.local([sky]), to: image))
        let base = readGrid(image)[50, 190][1]
        #expect(out[50, 5][1] < base - 30, "top darkened")
        #expect(out[50, 60][1] < base && out[50, 60][1] > out[50, 5][1], "fades")
        #expect(abs(Int(out[50, 150][1]) - Int(base)) <= 1, "bottom untouched")
        #expect(LocalAdjustment(kind: .brush, settings: .init(exposure: 1)).isEmpty, "a brush without paint does nothing")
    }

    @Test func tiltShiftKeepsTheBandSharp() {
        // Fine stripes everywhere; the middle band stays crisp, top and bottom blur.
        var g = Grid(width: 300, height: 200, pixels: [])
        for _ in 0..<200 { for x in 0..<300 { g.pixels.append(x % 4 < 2 ? [230, 230, 230, 255] : [20, 20, 20, 255]) } }
        let t = TiltShift(center: CurvePoint(0.5, 0.5), along: CurvePoint(0.9, 0.5), focus: 0.05, feather: 0.1, blur: 1, vivid: 0)
        let out = readGrid(RecipeRenderer.apply(.tiltShift(t), to: g.ciImage))
        func contrast(_ y: Int) -> Int {
            let row = (100..<200).map { Int(out[$0, y][1]) }
            return row.max()! - row.min()!
        }
        #expect(contrast(100) > 150, "band sharp: \(contrast(100))")
        #expect(contrast(10) < 60, "top blurred: \(contrast(10))")
        #expect(contrast(190) < 60, "bottom blurred: \(contrast(190))")
    }

    @Test func newEditsSaveAndPasteSensibly() throws {
        let local = LocalAdjustment(kind: .gradient, settings: .init(warmth: 0.3))
        let r = EditRecipe()
            .setting(.lens(LensCorrection(distortion: 0.2)))
            .setting(.local([local]))
            .setting(.tiltShift(TiltShift()))
        let back = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        let pasted = EditRecipe().pasting(r.pastableEdits)
        #expect(pasted.lens.distortion == 0.2, "lens fixes paste (same lens, same fix)")
        #expect(pasted.localAdjustments.isEmpty && pasted.tiltShift == nil, "spot edits don't")
    }
}
