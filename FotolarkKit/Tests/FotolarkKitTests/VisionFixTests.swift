import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Auto-straighten, auto-crop, red eye")
struct VisionFixTests {
    /// Sky over sea, with the horizon tilted by `degrees` (positive = clockwise on screen).
    func tiltedHorizon(degrees: Double) -> CIImage {
        let w = 1200.0, h = 800.0
        let sky = solid(r: 0.55, g: 0.75, b: 0.95, width: Int(w * 2), height: Int(h))
            .transformed(by: CGAffineTransform(translationX: -w / 2, y: h / 2))
        let sea = solid(r: 0.05, g: 0.2, b: 0.35, width: Int(w * 2), height: Int(h))
            .transformed(by: CGAffineTransform(translationX: -w / 2, y: -h / 2))
        let scene = sky.composited(over: sea)
        let t = CGAffineTransform(translationX: w / 2, y: h / 2).rotated(by: -degrees * .pi / 180)
            .translatedBy(x: -w / 2, y: -h / 2)
        return scene.transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    @Test(arguments: [6.0, -6.0])
    func horizonIsLeveledTheRightWay(tilt: Double) throws {
        let angle = try #require(testEngine.horizonStraightening(for: tiltedHorizon(degrees: tilt)),
                                 "Vision found no horizon")
        // Undoing a clockwise tilt needs a counterclockwise (negative) turn.
        #expect(abs(angle + tilt) < 1.5, "tilt \(tilt)°, suggested \(angle)°")
    }

    @Test func framingKeepsShapeAndRoom() throws {
        let crop = try #require(EditEngine.frame(CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3), imageAspect: 1.5))
        #expect(abs(crop.width - crop.height) < 1e-9, "same shape as the photo")
        #expect(crop.x <= 0.1 && crop.x + crop.width >= 0.3 && crop.y <= 0.2 && crop.y + crop.height >= 0.5)
        #expect(EditEngine.frame(CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.85), imageAspect: 1.5) == nil)
        let edge = try #require(EditEngine.frame(CGRect(x: 0.9, y: 0.0, width: 0.08, height: 0.1), imageAspect: 1))
        #expect(edge.x + edge.width <= 1 + 1e-9 && edge.y >= 0)
    }

    @Test func suggestedCropFindsTheSubject() throws {
        // A bright, detailed subject on the left of a plain dark photo.
        let bg = solid(r: 0.1, g: 0.1, b: 0.12, width: 1200, height: 800)
        let subject = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputWidth": 20, "inputColor0": CIColor(red: 1, green: 0.8, blue: 0.2), "inputColor1": CIColor(red: 0.9, green: 0.1, blue: 0.1),
        ])!.outputImage!.cropped(to: CGRect(x: 150, y: 300, width: 200, height: 200))
        let crop = try #require(testEngine.suggestedCrop(for: subject.composited(over: bg)))
        #expect(crop.x < 0.15 && crop.x + crop.width > 0.29, "covers the subject horizontally: \(crop)")
        #expect(crop.width < 0.9)
    }

    @Test func redEyeSpotDarkensRedOnly() {
        let bg = solid(r: 0.6, g: 0.5, b: 0.45, width: 200, height: 200)
        let pupil = solid(r: 0.85, g: 0.1, b: 0.1, width: 20, height: 20).transformed(by: CGAffineTransform(translationX: 90, y: 90))
        let eye = pupil.composited(over: bg)
        let spot = EyeSpot(x: 0.5, y: 0.5, radius: 0.06)
        #expect(testEngine.isRed(at: spot, in: eye))
        #expect(!testEngine.isRed(at: spot, in: bg))
        let fixed = readGrid(RecipeRenderer.apply(EditRecipe().setting(.redEye([spot])), to: eye))
        let center = fixed[100, 100], corner = fixed[5, 5]
        #expect(center[0] < 60, "pupil no longer red: \(center)")
        let original = readGrid(eye)[5, 5]
        #expect(zip(corner, original).allSatisfy { abs(Int($0) - Int($1)) <= 1 }, "skin untouched (±1 rounding): \(corner) vs \(original)")
    }
}
