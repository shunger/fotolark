import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// One brush stroke (or single click) of a retouching tool, stored on the original photo.
public struct RetouchStroke: Codable, Equatable, Sendable {
    public enum Tool: String, Codable, CaseIterable, Sendable {
        /// Replaces a blemish with nearby texture, matched to the surrounding light and color.
        case heal
        /// Copies pixels exactly from another spot.
        case clone
        /// Smooths skin.
        case soften
    }

    public var tool: Tool
    /// Path of the brush, normalized 0…1 with the origin top left.
    public var points: [CurvePoint]
    /// Brush radius as a fraction of the photo's longest side.
    public var radius: Double
    /// Heal and clone: where the pixels come from, as an offset from the stroke (normalized).
    public var sourceOffset: CurvePoint
    /// Soften: how much, 0…1.
    public var strength: Double

    public init(tool: Tool, points: [CurvePoint], radius: Double,
                sourceOffset: CurvePoint = CurvePoint(0, 0), strength: Double = 0.7) {
        self.tool = tool
        self.points = points
        self.radius = radius
        self.sourceOffset = sourceOffset
        self.strength = strength
    }
}

extension RecipeRenderer {
    /// Applies strokes in order, each on top of the result of the ones before.
    static func applyRetouch(_ strokes: [RetouchStroke], to image: CIImage) -> CIImage {
        var out = image
        for stroke in strokes {
            out = applyStroke(stroke, to: out)
        }
        return out
    }

    static func applyStroke(_ s: RetouchStroke, to image: CIImage) -> CIImage {
        let e = image.extent
        let longest = max(e.width, e.height)
        let r = s.radius * longest
        guard r >= 0.5, !s.points.isEmpty, let mask = strokeMask(s, in: e) else { return image }

        let replacement: CIImage
        switch s.tool {
        case .clone, .heal:
            // Pixels from the source spot, moved over the stroke.
            let shift = CGAffineTransform(translationX: -s.sourceOffset.x * e.width, y: s.sourceOffset.y * e.height)
            let patch = image.clampedToExtent().transformed(by: shift).cropped(to: e)
            if s.tool == .clone {
                replacement = patch
            } else {
                // Healing: keep the patch's fine texture, but take the broad light and color
                // from the area around the blemish. The blemish itself is first covered by
                // the patch so it doesn't leak into the "surroundings".
                let sigma = max(1.5, r * 0.8)
                let covered = patch.applyingFilter("CIBlendWithAlphaMask", parameters: [
                    kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask,
                ])
                let lowTarget = covered.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e)
                let lowPatch = patch.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: e)
                // patch − low(patch) + low(target)
                replacement = ImageMath.weightedSum([(patch, 1), (lowPatch, -1), (lowTarget, 1)], extent: e)
            }
        case .soften:
            // A smooth copy with a little of the original texture kept, so skin doesn't look plastic.
            let smooth = image.clampedToExtent()
                .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.08, "inputSharpness": 0.0])
                .applyingGaussianBlur(sigma: max(1, longest * 0.003))
                .cropped(to: e)
            replacement = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: smooth, kCIInputTimeKey: min(max(s.strength, 0), 1) * 0.85,
            ]).cropped(to: e)
        }
        return replacement.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask,
        ]).cropped(to: e)
    }

    static func strokeMask(_ s: RetouchStroke, in e: CGRect) -> CIImage? {
        dabMask(points: s.points, radius: s.radius, in: e)
    }

    /// Soft-edged dabs along a brush path, close enough together to form a smooth line.
    /// `radius` is a fraction of the longest side.
    static func dabMask(points: [CurvePoint], radius: Double, in e: CGRect) -> CIImage? {
        guard !points.isEmpty else { return nil }
        let longest = max(e.width, e.height)
        let r = radius * longest
        guard r >= 0.5 else { return nil }
        var centers: [CGPoint] = []
        let pts = points.map { CGPoint(x: e.minX + $0.x * e.width, y: e.maxY - $0.y * e.height) }
        centers.append(pts[0])
        let spacing = max(r * 0.35, 0.5)
        for (a, b) in zip(pts, pts.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            let steps = Int((d / spacing).rounded(.up))
            guard steps > 0 else { continue }
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                centers.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        // Cap the number of dabs so very long strokes stay fast.
        if centers.count > 400 {
            let step = Double(centers.count) / 400
            centers = (0..<400).map { centers[Int(Double($0) * step)] }
        }
        var mask: CIImage?
        for c in centers {
            let g = CIFilter.radialGradient()
            g.center = c
            g.radius0 = Float(r * 0.55)
            g.radius1 = Float(r)
            g.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            g.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            guard let dab = g.outputImage?.cropped(to: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)) else { continue }
            // Lighten keeps the strongest dab at each pixel, so overlaps don't build up edges.
            mask = mask.map { dab.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: $0]) } ?? dab
        }
        return mask?.cropped(to: e)
    }
}

extension EditEngine {
    /// Picks where spot healing should copy from: the nearby patch (at 2–3 brush widths
    /// in any of 12 directions) whose color best matches the area around the blemish and
    /// which has the least detail of its own. `center` is normalized, top-left origin.
    public func healSourceOffset(for center: CGPoint, radius: Double, in image: CIImage) -> CurvePoint {
        let e = image.extent
        let longest = max(e.width, e.height)
        let r = radius * longest
        let c = CGPoint(x: e.minX + center.x * e.width, y: e.maxY - center.y * e.height)
        func stats(_ rect: CGRect) -> (mean: SIMD3<Double>, variance: Double)? {
            let rect = rect.intersection(e)
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
            let mean = average(image, rect)
            let sq = average(image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image]), rect)
            let v = (sq - mean * mean)
            return (mean, max(v.x, 0) + max(v.y, 0) + max(v.z, 0))
        }
        // Color around the blemish: a 3r box minus the 2r box at its middle.
        let big = CGRect(x: c.x - 1.5 * r, y: c.y - 1.5 * r, width: 3 * r, height: 3 * r)
        let small = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let ring = (average(image, big) * 9 - average(image, small) * 4) / 5

        var best: (score: Double, offset: CGPoint) = (.infinity, CGPoint(x: 2.5 * r, y: 0))
        for distance in [2.2, 3.0] {
            for k in 0..<12 {
                let a = Double(k) * .pi / 6
                let off = CGPoint(x: cos(a) * distance * r, y: sin(a) * distance * r)
                let rect = CGRect(x: c.x + off.x - r, y: c.y + off.y - r, width: 2 * r, height: 2 * r)
                // Must lie fully inside the photo.
                guard e.contains(rect), let s = stats(rect) else { continue }
                let d = s.mean - ring
                let score = (d * d).sum() * 4 + s.variance
                if score < best.score { best = (score, off) }
            }
        }
        // Offsets are stored normalized with y pointing down.
        return CurvePoint(best.offset.x / e.width, -best.offset.y / e.height)
    }

    private func average(_ image: CIImage, _ rect: CGRect) -> SIMD3<Double> {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes {
            context.render(avg, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return SIMD3(Double(px[0]), Double(px[1]), Double(px[2]))
    }
}
