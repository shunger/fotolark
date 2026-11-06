import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A one-click look ("effect"), blended in at a chosen strength. Looks can be stacked.
public struct Look: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case blackAndWhite, sepia, warm, cool, filmGrain, softFocus, glow, crossProcess, lomo, focalBW

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .blackAndWhite: "Black & White"
            case .sepia: "Sepia"
            case .warm: "Warm"
            case .cool: "Cool"
            case .filmGrain: "Film Grain"
            case .softFocus: "Soft Focus"
            case .glow: "Glow"
            case .crossProcess: "Cross-Process"
            case .lomo: "Lomo"
            case .focalBW: "Focal B&W"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// 0…1: how much of the look is blended in.
    public var strength: Double
    /// Focal B&W: the spot kept in color, on the original photo (normalized, top-left
    /// origin), and its radius as a fraction of the longest side.
    public var focusX: Double
    public var focusY: Double
    public var focusRadius: Double

    public init(kind: Kind, strength: Double = 1, id: UUID = UUID(),
                focusX: Double = 0.5, focusY: Double = 0.5, focusRadius: Double = 0.25) {
        self.id = id
        self.kind = kind
        self.strength = strength
        self.focusX = focusX
        self.focusY = focusY
        self.focusRadius = focusRadius
    }
}

extension RecipeRenderer {
    static func applyLooks(_ looks: [Look], to image: CIImage) -> CIImage {
        looks.reduce(image) { applyLook($1, to: $0) }
    }

    static func applyLook(_ look: Look, to image: CIImage) -> CIImage {
        let e = image.extent
        let longest = max(e.width, e.height)
        let full: CIImage
        switch look.kind {
        case .blackAndWhite:
            full = mono(image).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
        case .sepia:
            full = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 1.0])
        case .warm:
            full = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 4800, y: 0),
            ]).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.1])
        case .cool:
            full = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 8500, y: 0),
            ])
        case .filmGrain:
            full = addGrain(to: image, amount: 0.09, scale: max(1, longest / 2000))
        case .softFocus:
            let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: longest * 0.006).cropped(to: e)
            full = image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: blurred, kCIInputTimeKey: 0.5])
        case .glow:
            full = image.clampedToExtent().applyingFilter("CIBloom", parameters: [
                kCIInputRadiusKey: longest * 0.012, kCIInputIntensityKey: 0.9,
            ]).cropped(to: e)
        case .crossProcess:
            func s(_ x: Double, _ k: Double) -> Double { 1 / (1 + exp(-k * (x - 0.5))) }
            func norm(_ f: @escaping (Double) -> Double) -> (Double) -> Double {
                let lo = f(0), hi = f(1)
                return { (f($0) - lo) / (hi - lo) }
            }
            full = applyLookupCurves(red: norm { s($0, 8) }, green: norm { s($0, 6) },
                                     blue: { 0.15 + 0.7 * $0 }, to: image)
        case .lomo:
            let punchy = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.35, kCIInputContrastKey: 1.2,
            ])
            full = applyVignette(amount: -1, size: 0.75, to: punchy)
        case .focalBW:
            // Black & white, except a soft circle around the focus point.
            let r = look.focusRadius * longest
            let g = CIFilter.radialGradient()
            g.center = CGPoint(x: e.minX + look.focusX * e.width, y: e.maxY - look.focusY * e.height)
            g.radius0 = Float(r * 0.7)
            g.radius1 = Float(r * 1.3)
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            g.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            full = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: mono(image), kCIInputMaskImageKey: g.outputImage!.cropped(to: e),
            ])
        }
        let strength = min(max(look.strength, 0), 1)
        guard strength < 1 else { return full.cropped(to: e) }
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: full.cropped(to: e), kCIInputTimeKey: strength,
        ]).cropped(to: e)
    }

    private static func mono(_ image: CIImage) -> CIImage {
        let w = CIVector(x: 0.3, y: 0.59, z: 0.11, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": w, "inputGVector": w, "inputBVector": w])
    }

    /// Grain from a fixed pattern, so the preview, every re-render and the export match.
    private static func addGrain(to image: CIImage, amount: Double, scale: Double) -> CIImage {
        let e = image.extent
        let tile = CIFilter.affineTile()
        tile.inputImage = GrainTexture.shared.image
        tile.transform = CGAffineTransform(scaleX: scale, y: scale)
        guard let pattern = tile.outputImage?.cropped(to: e) else { return image }
        // image + (texture − mean) × amount; the texture's mean is about 0.5 before color
        // management, which this bitmap skips.
        return ImageMath.weightedSum([(image, 1), (pattern, amount * 2)], bias: -amount, extent: e)
    }
}

/// A 256×256 tile of fixed random gray values for film grain.
final class GrainTexture: @unchecked Sendable {
    static let shared = GrainTexture()
    let image: CIImage

    private init() {
        let n = 256
        var seed: UInt64 = 0x5EED
        var bytes = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<(n * n) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8(truncatingIfNeeded: seed >> 56)
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v
        }
        image = CIImage(bitmapData: Data(bytes), bytesPerRow: n * 4, size: CGSize(width: n, height: n),
                        format: .RGBA8, colorSpace: nil)
    }
}

/// A saved combination of tone, color and look settings, applied in one click.
public struct EditPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Only the pastable edits (no crop, turns, retouching or text).
    public var recipe: EditRecipe

    public init(name: String, recipe: EditRecipe, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.recipe = recipe.pastableEdits
    }
}

extension EditRecipe {
    public var looks: [Look] {
        if case .looks(let l) = operation(.looks) { return l }
        return []
    }

    public var textOverlays: [TextOverlay] {
        if case .text(let t) = operation(.text) { return t }
        return []
    }
}
