import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

func close(_ a: Grid, _ b: Grid, tolerance: Int = 2) -> Bool {
    guard a.width == b.width, a.height == b.height else { return false }
    for (p, q) in zip(a.pixels, b.pixels) {
        for i in 0..<4 where abs(Int(p[i]) - Int(q[i])) > tolerance { return false }
    }
    return true
}

@Suite("Rendering")
struct RenderTests {
    let grid = Grid.numbered(width: 4, height: 3)

    @Test func emptyRecipeLeavesPixelsAlone() {
        let out = readGrid(RecipeRenderer.apply(EditRecipe(), to: grid.ciImage))
        #expect(close(out, grid))
    }

    @Test func rotateClockwiseTurnsTheRightWay() {
        let out = readGrid(RecipeRenderer.apply(EditRecipe().rotated(clockwise: true), to: grid.ciImage))
        #expect(close(out, grid.rotatedClockwise()), "got \(out)")
    }

    @Test func flipsMirrorTheRightWay() {
        let h = readGrid(RecipeRenderer.apply(EditRecipe().flipped(horizontally: true), to: grid.ciImage))
        #expect(close(h, grid.flippedHorizontally()))
        let v = readGrid(RecipeRenderer.apply(EditRecipe().flipped(horizontally: false), to: grid.ciImage))
        #expect(close(v, grid.flippedVertically()))
    }

    /// Any sequence of turns and flips, with a crop made first, must give the same pixels
    /// as doing each step to the picture one after another.
    @Test(arguments: [
        ["cw"], ["ccw"], ["h"], ["v"], ["cw", "h"], ["h", "cw"], ["cw", "v", "ccw"],
        ["v", "cw", "h", "cw"], ["h", "h", "cw", "cw", "v"],
    ])
    func turnsAndFlipsCompose(steps: [String]) {
        let big = Grid.numbered(width: 5, height: 4)
        // Crop the 3×2 block at (1, 1) first.
        var recipe = EditRecipe().setting(.crop(CropRect(x: 0.2, y: 0.25, width: 0.6, height: 0.5)))
        var expected = big.cropped(x: 1, y: 1, width: 3, height: 2)
        for step in steps {
            switch step {
            case "cw": recipe = recipe.rotated(clockwise: true); expected = expected.rotatedClockwise()
            case "ccw": recipe = recipe.rotated(clockwise: false); expected = expected.rotatedCounterclockwise()
            case "h": recipe = recipe.flipped(horizontally: true); expected = expected.flippedHorizontally()
            default: recipe = recipe.flipped(horizontally: false); expected = expected.flippedVertically()
            }
        }
        let out = readGrid(RecipeRenderer.apply(recipe, to: big.ciImage))
        #expect(close(out, expected), "steps \(steps): got \(out), expected \(expected)")
    }

    @Test func cropUsesTopLeftOrigin() {
        let recipe = EditRecipe().setting(.crop(CropRect(x: 0.5, y: 0, width: 0.5, height: 1.0 / 3)))
        let out = readGrid(RecipeRenderer.apply(recipe, to: grid.ciImage))
        #expect(close(out, grid.cropped(x: 2, y: 0, width: 2, height: 1)))
    }

    @Test func straightenHasNoBlankCornersAndMatchesPredictedSize() {
        let image = solid(r: 0.5, g: 0.6, b: 0.7, width: 400, height: 300)
        for degrees in [-45.0, -12, 3.5, 30] {
            let recipe = EditRecipe().setting(.straighten(degrees: degrees))
            let out = RecipeRenderer.apply(recipe, to: image)
            let predicted = Geometry.outputSize(of: recipe, source: PixelSize(width: 400, height: 300))
            #expect(PixelSize(out.extent.size) == predicted)
            #expect(out.extent.origin == .zero)
            let g = readGrid(out)
            #expect(g.pixels.allSatisfy { $0[3] == 255 }, "transparent pixels at \(degrees)°")
        }
    }

    @Test func straightenScaleIsExactForKnownCase() {
        // A square turned 45° fits a square of side 1/√2 inside it.
        let s = Geometry.straightenScale(width: 100, height: 100, degrees: 45)
        #expect(abs(s - 1 / 2.0.squareRoot()) < 1e-9)
    }

    @Test func outputSizeFollowsGeometry() {
        let recipe = EditRecipe()
            .rotated(clockwise: true)
            .setting(.crop(CropRect(x: 0, y: 0, width: 0.5, height: 0.25)))
            .setting(.resize(ResizeSpec(width: 100, height: 200)))
        let source = PixelSize(width: 4000, height: 3000)
        #expect(Geometry.outputSize(of: recipe, source: source, includeResize: false) == PixelSize(width: 1500, height: 1000))
        #expect(Geometry.outputSize(of: recipe, source: source) == PixelSize(width: 100, height: 200))
        let out = RecipeRenderer.apply(recipe, to: solid(r: 0.2, g: 0.2, b: 0.2, width: 4000, height: 3000))
        #expect(PixelSize(out.extent.size) == PixelSize(width: 100, height: 200))
    }

    @Test func previewSkipsResize() {
        let recipe = EditRecipe().setting(.resize(ResizeSpec(width: 10, height: 10)))
        let out = RecipeRenderer.apply(recipe, to: solid(r: 0.2, g: 0.2, b: 0.2), includeResize: false)
        #expect(PixelSize(out.extent.size) == PixelSize(width: 64, height: 48))
    }

    @Test func positiveTemperatureWarms() {
        var a = Adjustments()
        a.temperature = 0.6
        let warm = averageColor(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: solid(r: 0.5, g: 0.5, b: 0.5)))
        #expect(warm.r > warm.b + 10, "warm: \(warm)")
        a.temperature = -0.6
        let cool = averageColor(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: solid(r: 0.5, g: 0.5, b: 0.5)))
        #expect(cool.b > cool.r + 10, "cool: \(cool)")
    }

    @Test func positiveTintAddsMagenta() {
        var a = Adjustments()
        a.tint = 0.8
        let c = averageColor(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: solid(r: 0.5, g: 0.5, b: 0.5)))
        #expect(c.g < c.r && c.g < c.b, "tint: \(c)")
    }

    @Test(arguments: ["exposure", "brightness", "shadows", "fillLight", "whites", "blacks"])
    func brighteningSlidersBrighten(slider: String) {
        let base = gradient()
        var a = Adjustments()
        switch slider {
        case "exposure": a.exposure = 1
        case "brightness": a.brightness = 0.6
        case "shadows": a.shadows = 0.8
        case "fillLight": a.fillLight = 0.8
        case "whites": a.whites = 0.8
        default: a.blacks = 0.8
        }
        let before = averageColor(base)
        let after = averageColor(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: base))
        #expect(after.g > before.g + 1, "\(slider): \(before.g) → \(after.g)")
    }

    @Test func contrastSpreadsTones() {
        var a = Adjustments()
        a.contrast = 0.8
        let out = readGrid(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: gradient()))
        let original = readGrid(gradient())
        #expect(out.pixels.first![1] < original.pixels.first![1])
        #expect(out.pixels.last![1] > original.pixels.last![1])
    }

    @Test func saturationMinusOneIsGray() {
        var a = Adjustments()
        a.saturation = -1
        let c = averageColor(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: solid(r: 0.8, g: 0.3, b: 0.2)))
        #expect(abs(c.r - c.g) < 3 && abs(c.g - c.b) < 3, "\(c)")
    }

    /// A left-to-right dark-to-light ramp.
    func gradient() -> CIImage {
        let f = CIFilter(name: "CILinearGradient")!
        f.setValue(CIVector(x: 0, y: 0), forKey: "inputPoint0")
        f.setValue(CIVector(x: 256, y: 0), forKey: "inputPoint1")
        f.setValue(CIColor(red: 0.05, green: 0.05, blue: 0.05), forKey: "inputColor0")
        f.setValue(CIColor(red: 0.95, green: 0.95, blue: 0.95), forKey: "inputColor1")
        return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 256, height: 16))
    }
}

@Suite("One-click fixes")
struct AutoFixTests {
    @Test func autoContrastStretchesAFlatImage() {
        let flat = RenderTests().gradient().applyingFilter("CIColorControls", parameters: ["inputContrast": 0.4])
        let op = testEngine.autoContrast(for: flat)
        guard case .autoContrast(let levels) = op else { Issue.record("wrong op"); return }
        #expect(levels != .identity)
        let out = readGrid(RecipeRenderer.apply(EditRecipe().setting(op), to: flat))
        let before = readGrid(flat)
        let spreadBefore = Int(before.pixels.last![1]) - Int(before.pixels.first![1])
        let spreadAfter = Int(out.pixels.last![1]) - Int(out.pixels.first![1])
        #expect(spreadAfter > spreadBefore + 40, "\(spreadBefore) → \(spreadAfter)")
    }

    @Test func autoContrastLeavesFullRangeAlone() {
        let full = RenderTests().gradient().applyingFilter("CIColorControls", parameters: ["inputContrast": 3])
        #expect(testEngine.autoContrast(for: full).isIdentity)
    }

    @Test func autoColorRemovesABlueCast() {
        let bluish = RenderTests().gradient().applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.8, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.2, w: 0),
        ])
        let op = testEngine.autoColor(for: bluish)
        let before = averageColor(bluish)
        let after = averageColor(RecipeRenderer.apply(EditRecipe().setting(op), to: bluish))
        #expect(abs(after.b - after.r) < abs(before.b - before.r) / 2, "\(before) → \(after)")
    }

    @Test func autoColorLeavesGrayAlone() {
        #expect(testEngine.autoColor(for: RenderTests().gradient()).isIdentity)
    }

    @Test func magicFixIsFrozenAndReplaysTheSame() throws {
        let photo = RenderTests().gradient().applyingFilter("CIColorControls", parameters: ["inputContrast": 0.5])
        let op = testEngine.magicFix(for: photo)
        let recipe = EditRecipe().setting(op)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        let a = readGrid(RecipeRenderer.apply(recipe, to: photo))
        let b = readGrid(RecipeRenderer.apply(decoded, to: photo))
        #expect(a == b)
    }
}
