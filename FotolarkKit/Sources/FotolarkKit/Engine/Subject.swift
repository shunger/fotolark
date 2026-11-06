import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Where the main subject is: a grayscale picture (white = subject) at a modest size,
/// stretched over the photo when used. Kept in the recipe so the photo doesn't have to
/// be analyzed again every time it's drawn.
public struct SubjectMask: Codable, Equatable, Sendable {
    /// PNG, 8-bit gray.
    public var png: Data
    public var width: Int
    public var height: Int

    public init(png: Data, width: Int, height: Int) {
        self.png = png
        self.width = width
        self.height = height
    }

    /// The mask stretched over `extent`, white where the subject is.
    func image(over extent: CGRect) -> CIImage? {
        guard let mask = CIImage(data: png, options: [.colorSpace: NSNull()]) else { return nil }
        let sx = extent.width / mask.extent.width, sy = extent.height / mask.extent.height
        return mask.samplingLinear()
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX - mask.extent.minX * sx,
                                               y: extent.minY - mask.extent.minY * sy))
            .clampedToExtent()
            .cropped(to: extent)
    }

    /// Makes a mask from a grayscale image.
    static func make(from gray: CIImage, context: CIContext) -> SubjectMask? {
        let e = gray.extent.integral
        guard e.width >= 1, e.height >= 1,
              let cg = context.createCGImage(gray, from: e, format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.linearGray)!)
        else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return SubjectMask(png: data as Data, width: cg.width, height: cg.height)
    }
}

/// Portrait-style blur behind the subject.
public struct BackgroundBlur: Codable, Equatable, Sendable {
    /// 0…1.
    public var amount: Double
    public var mask: SubjectMask

    public init(amount: Double = 0.5, mask: SubjectMask) {
        self.amount = amount
        self.mask = mask
    }
}

extension EditEngine {
    /// Longest side the subject is looked for at; Vision's own models work at about this size.
    static let subjectAnalysisSize: CGFloat = 1024

    /// Finds the main subject (people, pets, objects in front), using Vision. Returns nil
    /// when there's no clear subject.
    public func subjectMask(for image: CIImage) -> SubjectMask? {
        let e = image.extent
        let scale = min(1, Self.subjectAnalysisSize / max(e.width, e.height))
        let small = image.normalizedToOrigin().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let size = CGRect(x: 0, y: 0, width: (e.width * scale).rounded(), height: (e.height * scale).rounded())
        guard let cg = context.createCGImage(small.cropped(to: size), from: size) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])

        var gray: CIImage?
        // Anything in front (people, pets, objects).
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        if (try? handler.perform([foreground])) != nil, let obs = foreground.results?.first, !obs.allInstances.isEmpty,
           let buffer = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler) {
            gray = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        } else {
            // Older Macs without that model: people only.
            let people = VNGeneratePersonSegmentationRequest()
            people.qualityLevel = .accurate
            if (try? handler.perform([people])) != nil, let buffer = people.results?.first?.pixelBuffer {
                gray = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            }
        }
        guard var mask = gray else { return nil }
        // One-channel masks: copy the value into every channel. (The bias makes the
        // image endless, so it's cropped back.)
        let r = CIVector(x: 1, y: 0, z: 0, w: 0)
        mask = mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": r, "inputGVector": r, "inputBVector": r,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]).cropped(to: mask.extent)
        // Fit to the analyzed size (person masks come back smaller).
        mask = mask.transformed(by: CGAffineTransform(scaleX: size.width / mask.extent.width,
                                                      y: size.height / mask.extent.height)).cropped(to: size)
        // Nothing found if the mask is almost empty.
        let avg = mask.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: size)])
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes {
            context.render(avg, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: nil)
        }
        guard px[0] > 0.01 else { return nil }
        return SubjectMask.make(from: mask, context: context)
    }

    /// The edited photo with everything but the subject made transparent, as PNG data.
    public func cutout(source: URL, recipe: EditRecipe) throws -> Data {
        let edited = RecipeRenderer.apply(recipe, to: try ImageLoader.loadFull(source))
        guard let mask = subjectMask(for: edited) else { throw SubjectError.noSubject }
        let png = cutoutPNG(edited, mask: mask)
        guard let png else { throw FotolarkError.cannotEncode("PNG") }
        return png
    }

    func cutoutPNG(_ image: CIImage, mask: SubjectMask) -> Data? {
        guard let cut = RecipeRenderer.applyCutout(mask, to: image),
              let cg = context.createCGImage(cut, from: image.extent, format: .RGBA8,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

public enum SubjectError: LocalizedError {
    case noSubject
    public var errorDescription: String? {
        "Fotolark couldn’t find a clear subject in this photo. It works best with people, pets or objects that stand out from the background."
    }
}

extension RecipeRenderer {
    /// Blurs what's behind the subject. The background is blurred without the subject in
    /// it, so the subject's colors don't smear into a halo around it.
    static func applyBackgroundBlur(_ b: BackgroundBlur, to image: CIImage) -> CIImage {
        let e = image.extent
        guard b.amount > 0, let subject = b.mask.image(over: e) else { return image }
        let sigma = b.amount * max(e.width, e.height) * 0.02
        // Background only: opacity = 1 − subject.
        let background = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: e),
            kCIInputMaskImageKey: subject.applyingFilter("CIColorInvert"),
        ])
        // Blurring premultiplied colors and then dividing by the blurred opacity averages
        // only background pixels.
        let blurred = background.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e)
            .applyingFilter("CIUnpremultiply")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: e)
        // The edge of the subject is softened a touch so it sits naturally.
        let edge = subject.clampedToExtent().applyingGaussianBlur(sigma: max(1, max(e.width, e.height) * 0.0015)).cropped(to: e)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: edge,
        ]).cropped(to: e)
    }

    /// The subject on a transparent background.
    static func applyCutout(_ mask: SubjectMask, to image: CIImage) -> CIImage? {
        let e = image.extent
        guard let subject = mask.image(over: e) else { return nil }
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: e),
            kCIInputMaskImageKey: subject,
        ]).cropped(to: e)
    }

    // MARK: Object removal

    /// Fills the area under `mask` from its surroundings: a smooth fill that flows in
    /// from the edges (repeatedly halving the photo, then filling each level from the
    /// one below), with fine texture borrowed from `patch` so it doesn't look smeared.
    static func fillHole(_ image: CIImage, mask: CIImage, patch: CIImage, textureSigma: Double) -> CIImage {
        let e = image.extent
        // Known pixels: opacity 1 − mask (the hole is see-through).
        let known = image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: e),
            kCIInputMaskImageKey: mask.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: -1), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]),
        ]).cropped(to: e)

        var levels: [CIImage] = [known]
        var current = known
        while max(current.extent.width, current.extent.height) > 4 && levels.count < 16 {
            current = current.clampedToExtent().applyingGaussianBlur(sigma: 0.8).cropped(to: current.extent)
                .transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
            current = current.cropped(to: current.extent.integral)
            levels.append(current)
        }
        // The smallest level, made solid.
        // (A bias makes the image endless, so it's cropped back.)
        let coarsest = levels.last!
        var filled = coarsest.applyingFilter("CIUnpremultiply")
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            .cropped(to: coarsest.extent)
        for level in levels.dropLast().reversed() {
            let sx = level.extent.width / filled.extent.width, sy = level.extent.height / filled.extent.height
            let up = filled.samplingLinear().clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .cropped(to: level.extent)
            filled = level.composited(over: up).cropped(to: level.extent)
        }
        let smooth = filled.cropped(to: e)
        // Fine texture from the patch: patch − blur(patch).
        let lowPatch = patch.clampedToExtent().applyingGaussianBlur(sigma: textureSigma).cropped(to: e)
        return ImageMath.weightedSum([(smooth, 1), (patch, 1), (lowPatch, -1)], extent: e)
    }
}
