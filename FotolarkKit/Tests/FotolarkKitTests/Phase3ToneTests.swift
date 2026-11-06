import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Curves, levels, color ranges, noise")
struct Phase3ToneTests {
    @Test func straightCurveIsIdentityAndSCurveAddsContrast() {
        #expect(ToneCurve.straight.isStraight)
        let s = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.25, 0.18), CurvePoint(0.75, 0.82), CurvePoint(1, 1)])
        #expect(s.value(at: 0.25) < 0.2 && s.value(at: 0.75) > 0.8)
        // Monotone: never goes backwards or overshoots.
        var last = -1.0
        for i in 0...100 {
            let v = s.value(at: Double(i) / 100)
            #expect(v >= last - 1e-9 && v >= 0 && v <= 1)
            last = v
        }
    }

    @Test func curvesRender() {
        var c = Curves()
        c.rgb = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)])
        let before = averageColor(solid(r: 0.5, g: 0.5, b: 0.5))
        let after = averageColor(RecipeRenderer.apply(EditRecipe().setting(.curves(c)), to: solid(r: 0.5, g: 0.5, b: 0.5)))
        #expect(abs(after.g - 0.7 * 255) < 4 && after.g > before.g + 30, "\(after)")
        c = Curves()
        c.blue = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.5, 0.3), CurvePoint(1, 1)])
        let warm = averageColor(RecipeRenderer.apply(EditRecipe().setting(.curves(c)), to: solid(r: 0.5, g: 0.5, b: 0.5)))
        #expect(warm.b < warm.r - 30, "blue curve only touches blue")
        #expect(EditRecipe().setting(.curves(Curves())).isEmpty, "a straight curve is no edit")
    }

    @Test func levelsMapping() {
        var l = ToneLevels()
        l.inputBlack = 0.2
        l.inputWhite = 0.8
        #expect(abs(l.value(at: 0.5) - 0.5) < 1e-9)
        #expect(l.value(at: 0.1) == 0 && l.value(at: 0.9) == 1)
        l = ToneLevels()
        l.gamma = 2
        #expect(l.value(at: 0.25) > 0.25)
        l = ToneLevels()
        l.outputBlack = 0.1
        let out = averageColor(RecipeRenderer.apply(EditRecipe().setting(.levels(l)), to: solid(r: 0, g: 0, b: 0)))
        #expect(abs(out.g - 0.1 * 255) < 3)
    }

    @Test func colorRangeTargetsOnlyItsColors() {
        var r = ColorRanges()
        r[.green].saturation = -1
        let green = averageColor(RecipeRenderer.apply(EditRecipe().setting(.colorRanges(r)), to: solid(r: 0.2, g: 0.7, b: 0.2)))
        let red = averageColor(RecipeRenderer.apply(EditRecipe().setting(.colorRanges(r)), to: solid(r: 0.8, g: 0.2, b: 0.2)))
        #expect(abs(green.r - green.g) < 8, "green made gray: \(green)")
        #expect(red.r > red.g + 100, "red untouched: \(red)")
        var hue = ColorRanges()
        hue[.blue].hue = 1  // toward purple
        let shifted = averageColor(RecipeRenderer.apply(EditRecipe().setting(.colorRanges(hue)), to: solid(r: 0.2, g: 0.3, b: 0.9)))
        #expect(shifted.r > 0.25 * 255, "blue shifted toward purple: \(shifted)")
        let grayIn = solid(r: 0.5, g: 0.5, b: 0.5)
        #expect(readGrid(RecipeRenderer.apply(EditRecipe().setting(.colorRanges(r)), to: grayIn)) == readGrid(grayIn) ||
                abs(averageColor(RecipeRenderer.apply(EditRecipe().setting(.colorRanges(r)), to: grayIn)).g - 127.5) < 2)
    }

    /// A gray image with random brightness and color speckles.
    func noisy() -> CIImage {
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 150))
        let faint = noise.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.06, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.06, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.06, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0.47, y: 0.47, z: 0.47, w: 1),  // opaque: the generator's alpha is random too
        ])
        // A bias makes the filter's output infinite; crop it back.
        return faint.cropped(to: CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    func spread(_ g: Grid, channel: (([UInt8]) -> Double)) -> Double {
        let v = g.pixels.map(channel)
        let m = v.reduce(0, +) / Double(v.count)
        return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
    }

    @Test func noiseReductionSmoothsBrightness() {
        var a = Adjustments()
        a.noiseReduction = 1
        let before = spread(readGrid(noisy())) { Double($0[1]) }
        let after = spread(readGrid(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: noisy()))) { Double($0[1]) }
        #expect(after < before * 0.9, "\(before) → \(after)")
    }

    @Test func colorNoiseReductionSmoothsColor() {
        var a = Adjustments()
        a.colorNoiseReduction = 1
        func chroma(_ p: [UInt8]) -> Double { Double(p[0]) - Double(p[2]) }
        let before = spread(readGrid(noisy()), channel: chroma)
        let after = spread(readGrid(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: noisy())), channel: chroma)
        #expect(after < before * 0.6, "\(before) → \(after)")
    }

    @Test func newOperationsRoundTripAndPaste() throws {
        var c = Curves()
        c.red = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(0.4, 0.5), CurvePoint(1, 1)])
        var r = ColorRanges()
        r[.orange].lightness = 0.3
        var l = ToneLevels()
        l.gamma = 1.4
        let recipe = EditRecipe().setting(.curves(c)).setting(.colorRanges(r)).setting(.levels(l))
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe)) == recipe)
        #expect(EditRecipe().pasting(recipe.pastableEdits) == recipe)
    }

    @Test func rawFilesAreRecognized() {
        for ext in ["dng", "CR2", "nef", "ARW", "RAF", "orf"] {
            #expect(ImageLoader.canOpen(URL(fileURLWithPath: "/x/IMG.\(ext)")), "\(ext)")
            #expect(ImageLoader.isRAW(URL(fileURLWithPath: "/x/IMG.\(ext)")))
        }
        #expect(!ImageLoader.isRAW(URL(fileURLWithPath: "/x/IMG.jpg")))
    }
}
