import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

// MARK: - Model

/// Light, color or blur changes painted onto part of the photo, or laid on with a
/// gradient (for example, darkening a bright sky). Stored on the original photo, like
/// retouching, so it stays put if the photo is cropped or turned later.
public struct LocalAdjustment: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Painted with a brush.
        case brush
        /// Full strength at `start`, fading to nothing at `end`.
        case gradient
    }

    /// One brush stroke; erasing strokes take the effect away again.
    public struct Stroke: Codable, Equatable, Sendable {
        /// Normalized 0…1, origin top left, on the original photo.
        public var points: [CurvePoint]
        /// Fraction of the photo's longest side.
        public var radius: Double
        public var erase: Bool

        public init(points: [CurvePoint], radius: Double, erase: Bool = false) {
            self.points = points
            self.radius = radius
            self.erase = erase
        }
    }

    /// What the adjustment does where it applies. Each is −1…+1 (blur 0…1).
    public struct Settings: Codable, Equatable, Sendable {
        public var exposure = 0.0
        public var contrast = 0.0
        public var saturation = 0.0
        public var warmth = 0.0
        public var blur = 0.0

        public init(exposure: Double = 0, contrast: Double = 0, saturation: Double = 0, warmth: Double = 0, blur: Double = 0) {
            self.exposure = exposure
            self.contrast = contrast
            self.saturation = saturation
            self.warmth = warmth
            self.blur = blur
        }

        public var isIdentity: Bool { self == Settings() }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func v(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
            exposure = try v(.exposure)
            contrast = try v(.contrast)
            saturation = try v(.saturation)
            warmth = try v(.warmth)
            blur = try v(.blur)
        }
    }

    public var id: UUID
    public var kind: Kind
    public var strokes: [Stroke]
    /// Gradient ends, normalized on the original photo.
    public var start: CurvePoint
    public var end: CurvePoint
    public var settings: Settings

    public init(id: UUID = UUID(), kind: Kind, strokes: [Stroke] = [], start: CurvePoint = CurvePoint(0.5, 0),
                end: CurvePoint = CurvePoint(0.5, 0.5), settings: Settings = Settings()) {
        self.id = id
        self.kind = kind
        self.strokes = strokes
        self.start = start
        self.end = end
        self.settings = settings
    }

    /// True when it can't change anything (no paint, or all settings at zero).
    public var isEmpty: Bool {
        settings.isIdentity || (kind == .brush && !strokes.contains { !$0.erase })
    }
}

/// A miniature-style focus band: sharp along a line, blurring away from it.
public struct TiltShift: Codable, Equatable, Sendable {
    /// Middle of the sharp band, normalized on the original photo.
    public var center: CurvePoint
    /// Another point along the band's middle line, which sets its angle.
    public var along: CurvePoint
    /// Half the height of the sharp band, as a fraction of the longest side.
    public var focus: Double
    /// How far the blur takes to build up, as a fraction of the longest side.
    public var feather: Double
    /// Blur strength, 0…1.
    public var blur: Double
    /// Extra color and contrast for the toy-model look, 0…1.
    public var vivid: Double

    public init(center: CurvePoint = CurvePoint(0.5, 0.55), along: CurvePoint = CurvePoint(0.9, 0.55),
                focus: Double = 0.06, feather: Double = 0.18, blur: Double = 0.6, vivid: Double = 0.4) {
        self.center = center
        self.along = along
        self.focus = focus
        self.feather = feather
        self.blur = blur
        self.vivid = vivid
    }
}

/// Fixes for the lens: bowed lines (distortion) and colored fringes at the edges
/// (chromatic aberration).
public struct LensCorrection: Codable, Equatable, Sendable {
    /// Positive straightens lines that bow outward (barrel, common on wide lenses);
    /// negative straightens lines that bow inward (pincushion, common when zoomed in). −1…+1.
    public var distortion: Double
    /// Shrinks or grows the red edges against the blue to line up colored fringes. −1…+1.
    public var chromatic: Double

    public init(distortion: Double = 0, chromatic: Double = 0) {
        self.distortion = distortion
        self.chromatic = chromatic
    }

    public var isIdentity: Bool { distortion == 0 && chromatic == 0 }

    /// Radial coefficient: a pixel at radius r (1 = corner) samples from r·(1 + k·r²).
    var k: Double { -0.25 * distortion }
    /// Extra scale of the red and blue channels' sampling, around the center.
    var redScale: Double { 1 + 0.004 * chromatic }
    var blueScale: Double { 1 - 0.004 * chromatic }
}

// MARK: - Rendering

extension RecipeRenderer {
    static func applyLocal(_ list: [LocalAdjustment], to image: CIImage) -> CIImage {
        let e = image.extent
        var out = image
        for adj in list where !adj.isEmpty {
            guard let mask = localMask(adj, in: e) else { continue }
            let adjusted = applyLocalSettings(adj.settings, to: out)
            out = adjusted.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: mask,
            ]).cropped(to: e)
        }
        return out
    }

    /// Where the adjustment applies: opaque where it's full strength.
    static func localMask(_ adj: LocalAdjustment, in e: CGRect) -> CIImage? {
        switch adj.kind {
        case .brush:
            var mask: CIImage?
            for stroke in adj.strokes {
                guard let dab = dabMask(points: stroke.points, radius: stroke.radius, in: e) else { continue }
                if stroke.erase {
                    // Keep the mask only where the eraser didn't go.
                    mask = mask?.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: dab])
                } else {
                    mask = mask.map { dab.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: $0]) } ?? dab
                }
            }
            return mask?.cropped(to: e)
        case .gradient:
            let g = CIFilter.smoothLinearGradient()
            g.point0 = pixelPoint(adj.start, in: e)
            g.point1 = pixelPoint(adj.end, in: e)
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            g.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            return g.outputImage?.cropped(to: e)
        }
    }

    static func applyLocalSettings(_ s: LocalAdjustment.Settings, to image: CIImage) -> CIImage {
        let e = image.extent
        var out = image
        if s.blur > 0 {
            let sigma = s.blur * max(e.width, e.height) * 0.012
            out = out.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e)
        }
        if s.exposure != 0 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure * 2])
        }
        if s.contrast != 0 || s.saturation != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + s.contrast * 0.5,
                kCIInputSaturationKey: 1 + s.saturation,
                kCIInputBrightnessKey: 0,
            ])
        }
        if s.warmth != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = out
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - s.warmth * 2500, y: 0)
            out = f.outputImage ?? out
        }
        return out.cropped(to: e)
    }

    static func applyTiltShift(_ t: TiltShift, to image: CIImage) -> CIImage {
        let e = image.extent
        let longest = max(e.width, e.height)
        guard t.blur > 0 || t.vivid > 0 else { return image }
        let c = pixelPoint(t.center, in: e)
        let a = pixelPoint(t.along, in: e)
        var dx = a.x - c.x, dy = a.y - c.y
        let len = hypot(dx, dy)
        if len < 0.5 { dx = 1; dy = 0 } else { dx /= len; dy /= len }
        let n = CGPoint(x: -dy, y: dx)
        let inner = t.focus * longest
        let outer = inner + max(t.feather * longest, 1)
        func ramp(_ sign: CGFloat) -> CIImage? {
            let g = CIFilter.smoothLinearGradient()
            g.point0 = CGPoint(x: c.x + n.x * inner * sign, y: c.y + n.y * inner * sign)
            g.point1 = CGPoint(x: c.x + n.x * outer * sign, y: c.y + n.y * outer * sign)
            g.color0 = CIColor(red: 0, green: 0, blue: 0)
            g.color1 = CIColor(red: 1, green: 1, blue: 1)
            return g.outputImage
        }
        var out = image
        if t.blur > 0, let up = ramp(1), let down = ramp(-1) {
            // White (full blur) away from the band on either side.
            let mask = up.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: down])
            out = image.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: [
                "inputMask": mask, kCIInputRadiusKey: t.blur * longest * 0.012,
            ]).cropped(to: e)
        }
        if t.vivid > 0 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1 + 0.45 * t.vivid, kCIInputContrastKey: 1 + 0.12 * t.vivid, kCIInputBrightnessKey: 0,
            ])
        }
        return out.cropped(to: e)
    }

    static func applyLens(_ lens: LensCorrection, to image: CIImage) -> CIImage {
        guard !lens.isIdentity else { return image }
        let e = image.extent
        let args: [String: Any] = [
            "extent": e, "k": lens.k, "red": lens.redScale, "blue": lens.blueScale,
        ]
        guard let out = try? LensWarpKernel.apply(withExtent: e, inputs: [image], arguments: args) else { return image }
        return out.cropped(to: e)
    }

    /// A normalized point (top-left origin) in Core Image pixel coordinates.
    static func pixelPoint(_ p: CurvePoint, in e: CGRect) -> CGPoint {
        CGPoint(x: e.minX + p.x * e.width, y: e.maxY - p.y * e.height)
    }
}

/// Remaps pixels for lens correction. Runs on the CPU inside Core Image's graph, so it
/// works the same everywhere without compiling GPU kernels.
final class LensWarpKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    struct Params {
        let extent: CGRect
        let k: Double
        let red: Double
        let blue: Double

        init?(_ args: [String: Any]?) {
            guard let args, let e = args["extent"] as? CGRect, let k = args["k"] as? Double,
                  let red = args["red"] as? Double, let blue = args["blue"] as? Double else { return nil }
            extent = e
            self.k = k
            self.red = red
            self.blue = blue
        }

        var center: CGPoint { CGPoint(x: extent.midX, y: extent.midY) }
        var norm: Double { max(hypot(extent.width, extent.height) / 2, 1) }
        /// Barrel fixes zoom in a little (no gaps); pincushion fixes are scaled so the
        /// corners stay corners.
        var fit: Double { k > 0 ? 1 / (1 + k) : 1 }

        /// Where the output pixel at `p` samples from, for a channel scaled by `s`.
        func source(_ x: Double, _ y: Double, scale s: Double) -> (Double, Double) {
            let dx = x - center.x, dy = y - center.y
            let r2 = (dx * dx + dy * dy) / (norm * norm)
            let f = (1 + k * r2) * fit * s
            return (center.x + dx * f, center.y + dy * f)
        }
    }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        guard let p = Params(arguments) else { return outputRect }
        // The mapping is radial and smooth, so the edges of the output rectangle bound
        // where it samples from.
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        let steps = 16
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let ox = Double(outputRect.minX), oy = Double(outputRect.minY)
            let ow = Double(outputRect.width), oh = Double(outputRect.height)
            let edge: [(Double, Double)] = [
                (ox + t * ow, oy), (ox + t * ow, oy + oh), (ox, oy + t * oh), (ox + ow, oy + t * oh),
            ]
            for (x, y) in edge {
                for s in [p.red, 1, p.blue] {
                    let (sx, sy) = p.source(x, y, scale: s)
                    minX = min(minX, sx); maxX = max(maxX, sx); minY = min(minY, sy); maxY = max(maxY, sy)
                }
            }
        }
        // A rectangle around the center may sample closer to it than its edges do.
        let r = CGRect(x: minX - 2, y: minY - 2, width: maxX - minX + 4, height: maxY - minY + 4)
            .union(outputRect.contains(p.center) ? CGRect(origin: p.center, size: .zero).insetBy(dx: -2, dy: -2) : .null)
        return r.intersection(p.extent).integral
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let input = inputs?.first, let p = Params(arguments) else { return }
        let src = UnsafePointer(input.baseAddress.assumingMemoryBound(to: SIMD4<Float>.self))
        let dst = output.baseAddress.assumingMemoryBound(to: SIMD4<Float>.self)
        let srcStride = input.bytesPerRow / 16
        let dstStride = output.bytesPerRow / 16
        let inR = input.region, outR = output.region
        let inW = Int(inR.width), inH = Int(inR.height)
        let outW = Int(outR.width), outH = Int(outR.height)
        guard inW > 0, inH > 0, outW > 0, outH > 0 else { return }
        let sameScale = p.red == 1 && p.blue == 1

        // Everything in Float, relative to the center, with rows running from the top
        // of each region down.
        let cx = Float(p.center.x), cy = Float(p.center.y)
        let invNorm2 = Float(1 / (p.norm * p.norm))
        let k = Float(p.k), fit = Float(p.fit)
        let redScale = Float(p.red), blueScale = Float(p.blue)
        let inMinX = Float(inR.minX), inMaxY = Float(inR.maxY)
        let maxX = Float(inW - 1), maxY = Float(inH - 1)
        let outMinX = Float(outR.minX), outMaxY = Float(outR.maxY)

        @inline(__always) func sample(_ sx: Float, _ sy: Float) -> SIMD4<Float> {
            let fx = min(max(sx - inMinX - 0.5, 0), maxX)
            let fy = min(max(inMaxY - sy - 0.5, 0), maxY)
            let x0 = Int(fx), y0 = Int(fy)
            let x1 = min(x0 + 1, inW - 1), y1 = min(y0 + 1, inH - 1)
            let tx = fx - Float(x0), ty = fy - Float(y0)
            let top = src[y0 * srcStride + x0] * (1 - tx) + src[y0 * srcStride + x1] * tx
            let bottom = src[y1 * srcStride + x0] * (1 - tx) + src[y1 * srcStride + x1] * tx
            return top * (1 - ty) + bottom * ty
        }

        // Rows in parallel, in bands.
        let bands = min(max(ProcessInfo.processInfo.activeProcessorCount, 1) * 2, outH)
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let rowStart = band * outH / bands, rowEnd = (band + 1) * outH / bands
            for row in rowStart..<rowEnd {
                let dy = outMaxY - Float(row) - 0.5 - cy
                let dy2 = dy * dy
                let line = dst + row * dstStride
                for col in 0..<outW {
                    let dx = outMinX + Float(col) + 0.5 - cx
                    let f = (1 + k * (dx * dx + dy2) * invNorm2) * fit
                    let g = sample(cx + dx * f, cy + dy * f)
                    if sameScale {
                        line[col] = g
                    } else {
                        let r = sample(cx + dx * f * redScale, cy + dy * f * redScale)
                        let b = sample(cx + dx * f * blueScale, cy + dy * f * blueScale)
                        line[col] = SIMD4(r.x, g.y, b.z, g.w)
                    }
                }
            }
        }
    }
}
