import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders recipes on the GPU and works out the one-click fixes.
/// Safe to share between threads: `CIContext` is thread-safe.
public final class EditEngine: @unchecked Sendable {
    public let context: CIContext

    public init(context: CIContext? = nil) {
        self.context = context ?? CIContext(options: [
            .cacheIntermediates: false,
            .name: "FotolarkKit",
        ])
    }

    // MARK: Rendering

    /// Renders `image` to a bitmap in the given color space (Display P3 by default, which
    /// keeps wide-gamut photos intact on screen).
    public func makeCGImage(_ image: CIImage, colorSpace: CGColorSpace? = nil, deep: Bool = false) -> CGImage? {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        return context.createCGImage(image, from: image.extent,
                                     format: deep ? .RGBA16 : .RGBA8,
                                     colorSpace: space)
    }

    public func render(_ recipe: EditRecipe, source: CIImage, includeResize: Bool = true,
                       colorSpace: CGColorSpace? = nil) -> CGImage? {
        makeCGImage(RecipeRenderer.apply(recipe, to: source, includeResize: includeResize), colorSpace: colorSpace)
    }

    // MARK: One-click fixes

    /// "Magic fix": asks Core Image which corrections this photo needs and freezes the
    /// answer into the recipe. `image` is the photo as edited so far (before this step).
    public func magicFix(for image: CIImage) -> EditOperation {
        let filters = image.autoAdjustmentFilters(options: [.redEye: false])
        let steps = filters.map { filter -> FilterStep in
            var params: [String: FilterValue] = [:]
            for key in filter.inputKeys where key != kCIInputImageKey {
                switch filter.value(forKey: key) {
                case let n as NSNumber: params[key] = .number(n.doubleValue)
                case let v as CIVector: params[key] = .vector((0..<v.count).map { Double(v.value(at: $0)) })
                default: break
                }
            }
            return FilterStep(name: filter.name, parameters: params)
        }
        return .magicFix(FilterChain(steps: steps))
    }

    /// Stretches the tones so the darkest 0.5% of pixels reach black and the brightest
    /// 0.5% reach white.
    public func autoContrast(for image: CIImage) -> EditOperation {
        guard let pixels = samplePixels(image, linear: false) else { return .autoContrast(.identity) }
        var histogram = [Int](repeating: 0, count: 1024)
        for p in pixels {
            let y = min(max(p.luminance, 0), 1)
            histogram[min(Int(y * 1023), 1023)] += 1
        }
        let total = pixels.count
        func percentile(_ q: Double) -> Double {
            let target = Int(Double(total) * q)
            var sum = 0
            for (i, n) in histogram.enumerated() {
                sum += n
                if sum > target { return Double(i) / 1023 }
            }
            return 1
        }
        // Values are gamma-encoded here. The limits stop a very dark or very bright
        // photo (night sky, snow) from being pushed to mid-gray.
        let black = min(percentile(0.005), 0.3)
        let white = max(percentile(0.995), 0.6)
        // Already full range: nothing to do.
        if black < 0.002 && white > 0.98 { return .autoContrast(.identity) }
        return .autoContrast(Levels(black: black, white: white))
    }

    /// Removes a color cast by nudging the average of the mid-tones toward gray.
    public func autoColor(for image: CIImage) -> EditOperation {
        guard let pixels = samplePixels(image) else { return .autoColor(.identity) }
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for p in pixels {
            let y = p.luminance
            // Skip near-black and clipped pixels; they carry no reliable color.
            guard y > 0.02, y < 0.9 else { continue }
            r += p.r; g += p.g; b += p.b; n += 1
        }
        guard n > 100, r > 0, g > 0, b > 0 else { return .autoColor(.identity) }
        r /= n; g /= n; b /= n

        // Gray world, applied at 75% strength and limited so odd scenes (a sunset, a
        // green forest) are not pushed too far.
        func soften(_ gain: Double) -> Double { min(max(1 + (gain - 1) * 0.75, 0.75), 1.33) }
        var gains = ChannelGains(red: soften(g / r), green: 1, blue: soften(g / b))
        // Keep overall brightness the same.
        let before = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let after = 0.2126 * r * gains.red + 0.7152 * g * gains.green + 0.0722 * b * gains.blue
        let k = before / after
        gains = ChannelGains(red: gains.red * k, green: gains.green * k, blue: gains.blue * k)
        let change = max(abs(gains.red - 1), abs(gains.green - 1), abs(gains.blue - 1))
        return .autoColor(change < 0.01 ? .identity : gains)
    }

    // MARK: Sampling

    struct Pixel {
        var r: Double, g: Double, b: Double
        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    }

    /// Reads a small copy of the image as RGB for analysis: linear light, or
    /// gamma-encoded (perceptual) values when `linear` is false.
    func samplePixels(_ image: CIImage, longestSide: CGFloat = 256, linear: Bool = true) -> [Pixel]? {
        let e = image.extent
        guard e.width >= 1, e.height >= 1, !e.isInfinite else { return nil }
        let scale = min(1, longestSide / max(e.width, e.height))
        let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).normalizedToOrigin()
        let w = max(1, Int(small.extent.width.rounded(.down)))
        let h = max(1, Int(small.extent.height.rounded(.down)))
        var data = [Float](repeating: 0, count: w * h * 4)
        let space = CGColorSpace(name: linear ? CGColorSpace.linearSRGB : CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buffer in
            context.render(small, toBitmap: buffer.baseAddress!, rowBytes: w * 16,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h),
                           format: .RGBAf, colorSpace: space)
        }
        var pixels: [Pixel] = []
        pixels.reserveCapacity(w * h)
        for i in stride(from: 0, to: data.count, by: 4) {
            pixels.append(Pixel(r: Double(data[i]), g: Double(data[i + 1]), b: Double(data[i + 2])))
        }
        return pixels
    }
}
