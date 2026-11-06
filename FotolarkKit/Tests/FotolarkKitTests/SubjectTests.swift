import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Object removal, background blur, cutout")
struct SubjectTests {
    /// Left half white (subject), right half black.
    func halfMask(width: Int, height: Int) -> SubjectMask {
        var g = Grid(width: width, height: height, pixels: [])
        for _ in 0..<height { for x in 0..<width { g.pixels.append(x < width / 2 ? [255, 255, 255, 255] : [0, 0, 0, 255]) } }
        return SubjectMask.make(from: g.ciImage, context: testEngine.context)!
    }

    @Test func maskSurvivesSavingAndStretches() {
        let mask = halfMask(width: 40, height: 20)
        #expect(mask.width == 40 && mask.height == 20)
        let big = readGrid(mask.image(over: CGRect(x: 0, y: 0, width: 400, height: 200))!)
        #expect(big[50, 100][0] > 240)
        #expect(big[350, 100][0] < 15)
    }

    @Test func removingAnObjectFillsItFromTheSurroundings() {
        // A smooth left-to-right gradient with a red block in the middle.
        let w = 200, h = 120
        var g = Grid(width: w, height: h, pixels: [])
        for y in 0..<h { for x in 0..<w {
            let inBlock = (85..<115).contains(x) && (45..<75).contains(y)
            g.pixels.append(inBlock ? [220, 20, 20, 255] : [UInt8(40 + x / 2), UInt8(90), UInt8(160 - x / 3), 255])
        } }
        // A scribble over the block.
        let pts = stride(from: 0.44, through: 0.56, by: 0.02).map { CurvePoint($0, 0.5) }
        let stroke = RetouchStroke(tool: .remove, points: pts, radius: 0.1, sourceOffset: CurvePoint(0, 0.3))
        let out = readGrid(RecipeRenderer.apply(.retouch([stroke]), to: g.ciImage))
        for (x, y) in [(90, 50), (100, 60), (110, 70)] {
            let expected = [40 + x / 2, 90, 160 - x / 3]
            let got = out[x, y]
            for c in 0..<3 {
                #expect(abs(Int(got[c]) - expected[c]) < 25, "(\(x),\(y)) channel \(c): \(got) vs \(expected)")
            }
        }
        // Far away, nothing changes.
        #expect(out[10, 10] == g[10, 10])
    }

    @Test func backgroundBlursButSubjectStaysSharpWithoutAHalo() {
        // Subject: solid red on the left. Background: fine blue/white stripes on the right.
        let w = 200, h = 100
        var g = Grid(width: w, height: h, pixels: [])
        for _ in 0..<h { for x in 0..<w {
            g.pixels.append(x < 100 ? [230, 30, 30, 255] : (x % 4 < 2 ? [240, 240, 255, 255] : [20, 40, 200, 255]))
        } }
        let blur = BackgroundBlur(amount: 1, mask: halfMask(width: 50, height: 25))
        let out = readGrid(RecipeRenderer.apply(.backgroundBlur(blur), to: g.ciImage))
        #expect(out[40, 50] == g[40, 50], "subject untouched")
        let row = (150..<190).map { Int(out[$0, 50][2]) }
        #expect(row.max()! - row.min()! < 40, "stripes blurred")
        // Just outside the subject the background mustn't pick up its red: red stays
        // level with green, as in the stripes themselves.
        let near = out[105, 50], far = out[180, 50]
        #expect(Int(near[0]) - Int(near[1]) < 12, "no red halo: \(near) vs \(far)")
    }

    @Test func cutoutMakesTheBackgroundTransparent() {
        let image = solid(r: 0.2, g: 0.6, b: 0.3, width: 100, height: 50)
        let cut = RecipeRenderer.applyCutout(halfMask(width: 100, height: 50), to: image)!
        let px = readGrid(cut)
        #expect(px[20, 25][3] == 255)
        #expect(px[80, 25][3] == 0)
        let png = testEngine.cutoutPNG(image, mask: halfMask(width: 100, height: 50))
        #expect(png != nil && png!.count > 100)
    }

    @Test func blurRecipeSavesAndStaysOffPaste() throws {
        let r = EditRecipe().setting(.backgroundBlur(BackgroundBlur(amount: 0.4, mask: halfMask(width: 8, height: 4))))
        let back = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(r))
        #expect(back == r)
        #expect(r.pastableEdits.isEmpty, "the mask belongs to this photo")
    }

    @Test func subjectDetectionRunsWithoutCrashing() {
        // A bright disc on a plain background. Whether Vision calls it a subject depends
        // on the Mac; this only checks the call is safe and any mask has the right shape.
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 300, y: 200), "inputRadius0": 90, "inputRadius1": 95,
            "inputColor0": CIColor(red: 0.9, green: 0.5, blue: 0.2), "inputColor1": CIColor(red: 0.2, green: 0.3, blue: 0.35),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
        if let mask = testEngine.subjectMask(for: disc) {
            #expect(abs(Double(mask.width) / Double(mask.height) - 1.5) < 0.02)
            // Where Vision does find it, the mask covers the disc and not the corner.
            let g = readGrid(mask.image(over: disc.extent)!)
            #expect(g[300, 200][0] > 200 && g[10, 10][0] < 30, "\(g[300, 200]) \(g[10, 10])")
        }
    }
}
