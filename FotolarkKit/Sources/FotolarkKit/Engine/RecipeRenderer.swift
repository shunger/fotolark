import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Replays an edit recipe on an image. Pure: no rendering happens here, Core Image only
/// builds a filter graph, which `EditEngine` renders on the GPU.
public enum RecipeRenderer {
    /// - Parameters:
    ///   - includeResize: false for the on-screen preview, which works from a smaller copy.
    public static func apply(_ recipe: EditRecipe, to source: CIImage, includeResize: Bool = true) -> CIImage {
        var image = source.normalizedToOrigin()
        for op in recipe.operations {
            if case .resize = op, !includeResize { continue }
            image = apply(op, to: image)
        }
        return image
    }

    public static func apply(_ op: EditOperation, to image: CIImage) -> CIImage {
        switch op {
        case .lens(let l): applyLens(l, to: image)
        case .local(let l): applyLocal(l, to: image)
        case .tiltShift(let t): applyTiltShift(t, to: image)
        case .backgroundBlur(let b): applyBackgroundBlur(b, to: image)
        case .magicFix(let chain): applyChain(chain, to: image)
        case .autoContrast(let levels): applyLevels(levels, to: image)
        case .autoColor(let gains): applyGains(gains, to: image)
        case .whiteBalance(let gains): applyGains(gains, to: image)
        case .redEye(let spots): applyRedEye(spots, to: image)
        case .retouch(let strokes): applyRetouch(strokes, to: image)
        case .adjust(let a): applyAdjustments(a, to: image)
        case .levels(let l): applyLookupCurves(red: l.value, green: l.value, blue: l.value, to: image)
        case .curves(let c):
            applyLookupCurves(red: { c.rgb.value(at: c.red.value(at: $0)) },
                              green: { c.rgb.value(at: c.green.value(at: $0)) },
                              blue: { c.rgb.value(at: c.blue.value(at: $0)) }, to: image)
        case .colorRanges(let r): applyColorRanges(r, to: image)
        case .looks(let l): applyLooks(l, to: image)
        case .text(let t): applyText(t, to: image)
        case .orient(let o): applyOrientation(o, to: image)
        case .straighten(let degrees): applyStraighten(degrees, to: image)
        case .crop(let rect): applyCrop(rect, to: image)
        case .resize(let spec): applyResize(spec, to: image)
        }
    }

    // MARK: Tone and color

    static func applyChain(_ chain: FilterChain, to image: CIImage) -> CIImage {
        var out = image
        for step in chain.steps {
            guard let filter = CIFilter(name: step.name) else { continue }
            filter.setValue(out, forKey: kCIInputImageKey)
            for (key, value) in step.parameters where filter.inputKeys.contains(key) {
                switch value {
                case .number(let n): filter.setValue(n, forKey: key)
                case .vector(let v): filter.setValue(CIVector(values: v.map { CGFloat($0) }, count: v.count), forKey: key)
                }
            }
            if let result = filter.outputImage { out = result }
        }
        return out.cropped(to: image.extent)
    }

    /// Levels are set in gamma-encoded (perceptual) values, as people expect from a
    /// histogram, so the stretch happens in that space.
    static func applyLevels(_ levels: Levels, to image: CIImage) -> CIImage {
        let range = max(levels.white - levels.black, 0.05)
        let s = CGFloat(1 / range)
        let b = CGFloat(-levels.black / range)
        let f = CIFilter.colorMatrix()
        f.rVector = CIVector(x: s, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: s, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: s, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: b, y: b, z: b, w: 0)
        f.inputImage = image.applyingFilter("CILinearToSRGBToneCurve")
        return f.outputImage?.applyingFilter("CISRGBToneCurveToLinear") ?? image
    }

    static func applyGains(_ g: ChannelGains, to image: CIImage) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image
        f.rVector = CIVector(x: g.red, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: g.green, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: g.blue, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        return f.outputImage ?? image
    }

    static func applyAdjustments(_ a: Adjustments, to image: CIImage) -> CIImage {
        var out = image
        let longest = max(image.extent.width, image.extent.height)

        if a.noiseReduction > 0 {
            // Core Image smooths differences below the noise level and sharpens the rest;
            // sharpening is eased off as strength rises so it never amplifies grain.
            let f = CIFilter.noiseReduction()
            f.inputImage = out
            f.noiseLevel = Float(0.01 + a.noiseReduction * 0.09)
            f.sharpness = Float(0.4 * (1 - a.noiseReduction))
            var smoothed = (f.outputImage ?? out).cropped(to: image.extent)
            // Stronger settings add a median filter, which removes random grain but keeps edges.
            if a.noiseReduction > 0.3 {
                let median = smoothed.clampedToExtent().applyingFilter("CIMedianFilter").cropped(to: image.extent)
                smoothed = smoothed.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: median, kCIInputTimeKey: (a.noiseReduction - 0.3) / 0.7,
                ]).cropped(to: image.extent)
            }
            out = smoothed
        }
        if a.colorNoiseReduction > 0 {
            // Take each pixel's color from a blurred copy but keep its own brightness:
            // result = blurred + (brightness(original) − brightness(blurred)).
            let blurred = out.clampedToExtent()
                .applyingGaussianBlur(sigma: max(2, longest * 0.004) * (0.5 + a.colorNoiseReduction * 1.5))
                .cropped(to: image.extent)
            let colorOnly = ImageMath.weightedSum([
                (blurred, 1), (ImageMath.luminance(out), 1), (ImageMath.luminance(blurred), -1),
            ], extent: image.extent)
            out = out.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: colorOnly, kCIInputTimeKey: min(a.colorNoiseReduction, 1),
            ]).cropped(to: image.extent)
        }

        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = out
            f.ev = Float(a.exposure)
            out = f.outputImage ?? out
        }

        // Shadows and fill light both lift the dark areas; negative highlights pull
        // bright areas down. All three use Core Image's local highlight/shadow filter.
        let shadowAmount = min(max(a.shadows + a.fillLight, -1), 1)
        let highlightAmount = a.highlights < 0 ? 1 + a.highlights * 0.7 : 1
        if shadowAmount != 0 || highlightAmount != 1 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = out
            f.shadowAmount = Float(shadowAmount)
            f.highlightAmount = Float(highlightAmount)
            f.radius = Float(max(1, longest * 0.01))
            out = f.outputImage ?? out
        }

        // Whites, blacks and positive highlights shape a five-point tone curve.
        if a.whites != 0 || a.blacks != 0 || a.highlights > 0 {
            let f = CIFilter.toneCurve()
            f.inputImage = out
            f.point0 = CGPoint(x: 0, y: max(0, a.blacks) * 0.12)
            f.point1 = CGPoint(x: 0.25, y: 0.25 + a.blacks * 0.06)
            f.point2 = CGPoint(x: 0.5, y: 0.5 + max(0, a.highlights) * 0.02)
            f.point3 = CGPoint(x: 0.75, y: 0.75 + a.whites * 0.06 + max(0, a.highlights) * 0.08)
            f.point4 = CGPoint(x: 1, y: 1 + min(0, a.whites) * 0.12)
            out = f.outputImage ?? out
        }

        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = out
            f.brightness = Float(a.brightness * 0.25)
            f.contrast = Float(1 + a.contrast * 0.35)
            f.saturation = Float(1 + a.saturation)
            out = f.outputImage ?? out
        }

        if a.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = out
            f.amount = Float(a.vibrance)
            out = f.outputImage ?? out
        }

        if a.temperature != 0 || a.tint != 0 {
            // Telling Core Image the photo's white point is warmer than it is makes the
            // result cooler, so a positive (warmer) slider lowers the target temperature.
            let f = CIFilter.temperatureAndTint()
            f.inputImage = out
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - a.temperature * 2500, y: -a.tint * 60)
            out = f.outputImage ?? out
        }

        // Detail. Radii scale with the image, so the preview (a smaller copy) looks like
        // the full-size export.
        if a.structure != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = out
            f.radius = Float(max(1, longest * 0.004))
            f.intensity = Float(a.structure * 0.8)
            out = f.outputImage ?? out
        }
        if a.clarity != 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = out
            f.radius = Float(max(2, longest * 0.02))
            f.intensity = Float(a.clarity * 0.5)
            out = f.outputImage ?? out
        }
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = out
            f.sharpness = Float(a.sharpness * 1.2)
            f.radius = Float(max(0.5, longest * 0.0004))
            out = f.outputImage ?? out
        }

        if a.vignette != 0 {
            out = applyVignette(amount: a.vignette, size: a.vignetteSize, to: out.cropped(to: image.extent))
        }

        return out.cropped(to: image.extent)
    }

    // MARK: Red eye

    /// Inside each spot, red is pulled down to the level of green and blue, which turns a
    /// red pupil dark without touching the rest of the eye.
    static func applyRedEye(_ spots: [EyeSpot], to image: CIImage) -> CIImage {
        let e = image.extent
        let longest = max(e.width, e.height)
        var mask: CIImage?
        for spot in spots {
            let r = spot.radius * longest
            let g = CIFilter.radialGradient()
            g.center = CGPoint(x: e.minX + spot.x * e.width, y: e.maxY - spot.y * e.height)
            g.radius0 = Float(r * 0.7)
            g.radius1 = Float(r * 1.1)
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            g.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            guard let one = g.outputImage else { continue }
            mask = mask.map { one.composited(over: $0) } ?? one
        }
        guard let mask else { return image }
        let half = CIVector(x: 0, y: 0.5, z: 0.5, w: 0)
        let noRed = image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": half])
        let fixed = image.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: noRed])
        return fixed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask.cropped(to: e),
        ]).cropped(to: e)
    }

    // MARK: Lookup tables

    /// Per-channel curves as a lookup table, applied to gamma-encoded values.
    static func applyLookupCurves(red: (Double) -> Double, green: (Double) -> Double, blue: (Double) -> Double,
                                  to image: CIImage) -> CIImage {
        let n = 1024
        var table = [Float](repeating: 0, count: n * 3)
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            table[i * 3] = Float(red(x))
            table[i * 3 + 1] = Float(green(x))
            table[i * 3 + 2] = Float(blue(x))
        }
        let f = CIFilter.colorCurves()
        f.inputImage = image
        f.curvesData = table.withUnsafeBytes { Data($0) }
        f.curvesDomain = CIVector(x: 0, y: 1)
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return f.outputImage ?? image
    }

    private static let cubeCache = CubeCache()

    static func applyColorRanges(_ ranges: ColorRanges, to image: CIImage) -> CIImage {
        let size = 32
        let data = cubeCache.data(for: ranges) {
            var cube = [Float](repeating: 0, count: size * size * size * 4)
            var i = 0
            for b in 0..<size {
                for g in 0..<size {
                    for r in 0..<size {
                        let (nr, ng, nb) = ranges.apply(r: Double(r) / Double(size - 1), g: Double(g) / Double(size - 1),
                                                        b: Double(b) / Double(size - 1))
                        cube[i] = Float(nr); cube[i + 1] = Float(ng); cube[i + 2] = Float(nb); cube[i + 3] = 1
                        i += 4
                    }
                }
            }
            return cube.withUnsafeBytes { Data($0) }
        }
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(size)
        f.cubeData = data
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return f.outputImage ?? image
    }

    /// Darkens (negative amount) or lightens (positive) toward the corners with a smooth
    /// radial mask, so both directions look the same.
    static func applyVignette(amount: Double, size: Double, to image: CIImage) -> CIImage {
        let e = image.extent
        let halfDiagonal = hypot(e.width, e.height) / 2
        // size 0 = only the far corners; size 1 = reaches well into the middle.
        let inner = halfDiagonal * (0.95 - 0.7 * min(max(size, 0), 1))
        let mask = CIFilter.radialGradient()
        mask.center = CGPoint(x: e.midX, y: e.midY)
        mask.radius0 = Float(inner)
        mask.radius1 = Float(halfDiagonal)
        mask.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        mask.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let gradient = mask.outputImage?.cropped(to: e) else { return image }
        let strength = min(abs(amount), 1)
        let adjusted: CIImage
        if amount < 0 {
            adjusted = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2.0 * strength])
        } else {
            adjusted = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.2 * strength])
        }
        // Mix: the adjusted image shows through where the gradient is opaque (the corners).
        return adjusted.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: gradient,
        ]).cropped(to: e)
    }

    // MARK: Geometry

    static func applyOrientation(_ o: Orientation, to image: CIImage) -> CIImage {
        var out = image
        if o.mirrored { out = out.oriented(.upMirrored).normalizedToOrigin() }
        for _ in 0..<o.quarterTurns { out = out.oriented(.right).normalizedToOrigin() }
        return out
    }

    static func applyStraighten(_ degrees: Double, to image: CIImage) -> CIImage {
        guard degrees != 0 else { return image }
        let e = image.extent
        let size = Geometry.straightenedSize(PixelSize(e.size), degrees: degrees)
        let center = CGPoint(x: e.midX, y: e.midY)
        // Core Image angles run counterclockwise; ours run clockwise.
        let t = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        // Whole-pixel origin, so the crop doesn't land between pixels.
        let rect = CGRect(x: (center.x - CGFloat(size.width) / 2).rounded(.down),
                          y: (center.y - CGFloat(size.height) / 2).rounded(.down),
                          width: CGFloat(size.width),
                          height: CGFloat(size.height))
        // Clamping first keeps the edges of the crop free of transparent fringes.
        return image.clampedToExtent()
            .transformed(by: t, highQualityDownsample: true)
            .cropped(to: rect)
            .normalizedToOrigin()
    }

    static func applyCrop(_ crop: CropRect, to image: CIImage) -> CIImage {
        let size = PixelSize(image.extent.size)
        let r = Geometry.cropPixelRect(crop, in: size)
        // Our crop origin is top left; Core Image's is bottom left.
        let rect = CGRect(x: image.extent.minX + CGFloat(r.x),
                          y: image.extent.minY + CGFloat(size.height - r.y - r.height),
                          width: CGFloat(r.width),
                          height: CGFloat(r.height))
        return image.cropped(to: rect).normalizedToOrigin()
    }

    static func applyResize(_ spec: ResizeSpec, to image: CIImage) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, spec.width > 0, spec.height > 0 else { return image }
        let sx = Double(spec.width) / e.width
        let sy = Double(spec.height) / e.height
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image.clampedToExtent()
        f.scale = Float(sy)
        f.aspectRatio = Float(sx / sy)
        let out = f.outputImage ?? image
        return out.cropped(to: CGRect(x: e.minX * sx, y: e.minY * sy,
                                      width: CGFloat(spec.width), height: CGFloat(spec.height)))
            .normalizedToOrigin()
    }
}

extension CIImage {
    /// Moves the image so its extent starts at (0, 0).
    func normalizedToOrigin() -> CIImage {
        let e = extent
        guard !e.isInfinite, e.origin != .zero else { return self }
        return transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }
}

/// Remembers the most recent color cube, so dragging an unrelated slider doesn't
/// rebuild it on every frame.
final class CubeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: ColorRanges?
    private var value: Data?

    func data(for ranges: ColorRanges, make: () -> Data) -> Data {
        if let hit = lock.withLock({ key == ranges ? value : nil }) { return hit }
        let made = make()
        lock.withLock { key = ranges; value = made }
        return made
    }
}
