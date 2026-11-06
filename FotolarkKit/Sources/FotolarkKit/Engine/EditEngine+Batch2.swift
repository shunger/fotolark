import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Brightness distribution of an image, for the histogram display.
public struct Histogram: Equatable, Sendable {
    /// Counts per bin, scaled so the tallest bin of any channel is 1.
    public var red: [Double]
    public var green: [Double]
    public var blue: [Double]
    public var luminance: [Double]

    public var binCount: Int { luminance.count }
}

extension EditEngine {
    // MARK: White balance picker

    /// Channel gains that make the area around `point` neutral gray.
    ///
    /// - Parameters:
    ///   - image: the photo as shown, with the edits made before white balance.
    ///   - point: where the person clicked, normalized 0…1 with the origin top left.
    /// - Returns: nil when the spot is too dark or too bright to judge color from.
    public func neutralGains(in image: CIImage, at point: CGPoint, radius: Double = 0.006) -> ChannelGains? {
        let e = image.extent
        guard !e.isInfinite, e.width > 0, e.height > 0 else { return nil }
        let side = max(3, max(e.width, e.height) * radius * 2)
        let center = CGPoint(x: e.minX + point.x * e.width, y: e.maxY - point.y * e.height)
        let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side).intersection(e)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }

        let avg = CIFilter.areaAverage()
        avg.inputImage = image
        avg.extent = rect
        guard let one = avg.outputImage else { return nil }
        var px = [Float](repeating: 0, count: 4)
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        px.withUnsafeMutableBytes {
            context.render(one, toBitmap: $0.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        }
        let r = Double(px[0]), g = Double(px[1]), b = Double(px[2])
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard y > 0.01, y < 0.95, r > 0.001, g > 0.001, b > 0.001 else { return nil }
        // Scale each channel to the gray of the same brightness.
        let gains = ChannelGains(red: min(max(y / r, 0.4), 2.5), green: min(max(y / g, 0.4), 2.5), blue: min(max(y / b, 0.4), 2.5))
        return gains
    }

    /// The image to sample for the white balance picker: the edits that come before white
    /// balance, plus the turns, straightening and crop, so the click lines up with the screen.
    public static func whiteBalanceSamplingImage(_ recipe: EditRecipe, source: CIImage) -> CIImage {
        let ops = recipe.operations.filter { $0.kind < .whiteBalance || ($0.kind.isGeometry && $0.kind != .resize) }
        return RecipeRenderer.apply(EditRecipe(operations: ops), to: source, includeResize: false)
    }

    // MARK: Histogram

    public func histogram(of image: CIImage, bins: Int = 64) -> Histogram? {
        guard let pixels = samplePixels(image, longestSide: 256, linear: false), !pixels.isEmpty else { return nil }
        var r = [Double](repeating: 0, count: bins), g = r, b = r, l = r
        func bin(_ v: Double) -> Int { min(max(Int(v * Double(bins)), 0), bins - 1) }
        for p in pixels {
            r[bin(p.r)] += 1
            g[bin(p.g)] += 1
            b[bin(p.b)] += 1
            l[bin(p.luminance)] += 1
        }
        // Ignore the end bins when scaling so a lot of pure black or white doesn't flatten the rest.
        let peak = max(1, [r, g, b, l].map { $0.dropFirst().dropLast().max() ?? 1 }.max() ?? 1)
        func norm(_ a: [Double]) -> [Double] { a.map { min($0 / peak, 1) } }
        return Histogram(red: norm(r), green: norm(g), blue: norm(b), luminance: norm(l))
    }

    // MARK: Copy and paste edits

    /// Works out the one-click fixes in `recipe` again for a different photo, since a
    /// Magic fix tuned for one photo would be wrong for another.
    public func recomputingAutoFixes(_ recipe: EditRecipe, for source: CIImage) -> EditRecipe {
        var out = recipe
        for kind in [EditOperation.Kind.magicFix, .autoContrast, .autoColor] where recipe.operation(kind) != nil {
            let before = RecipeRenderer.apply(out.prefix(before: kind), to: source)
            let op: EditOperation
            switch kind {
            case .magicFix: op = magicFix(for: before)
            case .autoContrast: op = autoContrast(for: before)
            default: op = autoColor(for: before)
            }
            // Stored directly (not via `setting`) so the fix stays switched on even when
            // this photo happens to need no change.
            if let i = out.operations.firstIndex(where: { $0.kind == kind }) {
                out.operations[i] = op
            }
        }
        return out
    }
}

extension EditRecipe {
    /// Edits that copy and paste between photos: tone and color. Turns, straightening,
    /// crop and size belong to each photo and are left alone.
    public static let pastableKinds: [EditOperation.Kind] = [.magicFix, .autoContrast, .autoColor, .whiteBalance, .adjust,
                                                             .levels, .curves, .colorRanges, .looks]

    /// Just the edits that can be pasted onto other photos.
    public var pastableEdits: EditRecipe {
        EditRecipe(operations: operations.filter { Self.pastableKinds.contains($0.kind) })
    }

    /// This recipe with its tone and color edits replaced by those in `copied`.
    public func pasting(_ copied: EditRecipe) -> EditRecipe {
        var r = self
        for kind in Self.pastableKinds {
            r = r.removing(kind)
            if let op = copied.operation(kind) { r = r.setting(op) }
        }
        return r
    }
}
