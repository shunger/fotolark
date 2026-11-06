import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Detail, vignette and white balance")
struct Batch2RenderTests {
    @Test func vignetteDarkensOrLightensCornersOnly() {
        let flat = solid(r: 0.5, g: 0.5, b: 0.5, width: 200, height: 150)
        for amount in [-0.8, 0.8] {
            var a = Adjustments()
            a.vignette = amount
            let g = readGrid(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: flat))
            let center = Int(g[100, 75][1]), corner = Int(g[0, 0][1])
            let original = Int(readGrid(flat)[100, 75][1])
            #expect(abs(center - original) <= 2, "center moved at \(amount)")
            if amount < 0 { #expect(corner < original - 20) } else { #expect(corner > original + 20) }
        }
    }

    @Test(arguments: ["sharpness", "clarity", "structure"])
    func detailSlidersAddContrastToEdges(slider: String) {
        // A soft edge: detail sliders should make it steeper.
        let edge = RenderTests().gradient().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 2])
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 16))
        var a = Adjustments()
        switch slider {
        case "sharpness": a.sharpness = 1
        case "clarity": a.clarity = 1
        default: a.structure = 1
        }
        let before = readGrid(edge), after = readGrid(RecipeRenderer.apply(EditRecipe().settingAdjustments(a), to: edge))
        func spread(_ g: Grid) -> Int { Int(g[250, 8][1]) - Int(g[5, 8][1]) }
        #expect(spread(after) >= spread(before), "\(slider)")
        #expect(after != before, "\(slider) changed nothing")
    }

    @Test func pickingAGrayAreaNeutralizesIt() throws {
        // A bluish-gray photo; picking anywhere should make it neutral.
        let cast = solid(r: 0.40, g: 0.45, b: 0.60, width: 100, height: 80)
        let gains = try #require(testEngine.neutralGains(in: cast, at: CGPoint(x: 0.5, y: 0.5)))
        let fixed = averageColor(RecipeRenderer.apply(EditRecipe().setting(.whiteBalance(gains)), to: cast))
        #expect(abs(fixed.r - fixed.b) < 3 && abs(fixed.g - fixed.b) < 3, "\(fixed)")
    }

    @Test func pickingBlackOrWhiteIsRefused() {
        #expect(testEngine.neutralGains(in: solid(r: 0, g: 0, b: 0), at: CGPoint(x: 0.5, y: 0.5)) == nil)
        #expect(testEngine.neutralGains(in: solid(r: 1, g: 1, b: 1), at: CGPoint(x: 0.5, y: 0.5)) == nil)
    }

    @Test func samplingImageFollowsCropAndTurns() {
        // Left half red, right half blue; after a crop to the right half, any point is blue.
        let red = solid(r: 0.8, g: 0.1, b: 0.1, width: 50, height: 40)
        let blue = solid(r: 0.1, g: 0.1, b: 0.8, width: 50, height: 40).transformed(by: CGAffineTransform(translationX: 50, y: 0))
        let photo = blue.composited(over: red)
        let recipe = EditRecipe().setting(.crop(CropRect(x: 0.5, y: 0, width: 0.5, height: 1)))
            .settingAdjustments({ var a = Adjustments(); a.saturation = -1; return a }())
        let sample = EditEngine.whiteBalanceSamplingImage(recipe, source: photo)
        let c = averageColor(sample)
        #expect(c.b > c.r + 100, "crop applied, later edits (saturation) not")
    }

    @Test func histogramReflectsTones() throws {
        let dark = try #require(testEngine.histogram(of: solid(r: 0.1, g: 0.1, b: 0.1)))
        let bright = try #require(testEngine.histogram(of: solid(r: 0.9, g: 0.9, b: 0.9)))
        let darkPeak = dark.luminance.firstIndex(of: dark.luminance.max()!)!
        let brightPeak = bright.luminance.firstIndex(of: bright.luminance.max()!)!
        #expect(darkPeak < 16 && brightPeak > 48)
        #expect(dark.binCount == 64)
    }

    @Test func oldSidecarsWithoutNewSlidersStillOpen() throws {
        let json = #"{"version":1,"operations":[{"op":"adjust","value":{"exposure":0.5}}]}"#
        let r = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(r.adjustments.vignetteSize == 0.5 && r.adjustments.sharpness == 0)
    }
}

@Suite("Copy and paste edits")
struct PasteTests {
    @Test func pasteReplacesToneAndColorButKeepsGeometry() {
        var a = Adjustments()
        a.exposure = 0.7
        let source = EditRecipe().settingAdjustments(a).setting(.whiteBalance(ChannelGains(red: 1.1, green: 1, blue: 0.9)))
            .setting(.crop(CropRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        let target = EditRecipe().rotated(clockwise: true).setting(.autoColor(ChannelGains(red: 1.2, green: 1, blue: 1)))
        let result = target.pasting(source.pastableEdits)
        #expect(result.adjustments.exposure == 0.7)
        #expect(result.operation(.whiteBalance) != nil)
        #expect(result.operation(.autoColor) == nil, "pasting replaces all tone and color edits")
        #expect(result.orientation.quarterTurns == 1)
        #expect(result.cropRect == nil, "crop isn't copied")
    }

    @Test func autoFixesAreWorkedOutAgainForEachPhoto() {
        let bluish = RenderTests().gradient().applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.8, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 1.2, w: 0),
        ])
        let gray = RenderTests().gradient()
        let fromBluish = EditRecipe().setting(testEngine.autoColor(for: bluish))
        let forGray = testEngine.recomputingAutoFixes(fromBluish, for: gray)
        #expect(forGray.operation(.autoColor) != nil, "still switched on")
        #expect(forGray.operation(.autoColor)?.isIdentity == true, "a gray photo needs no color fix")
    }
}
