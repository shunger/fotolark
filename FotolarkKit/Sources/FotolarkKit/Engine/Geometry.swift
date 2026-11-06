import Foundation

public struct PixelSize: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    public var cgSize: CGSize { CGSize(width: width, height: height) }
    public var swapped: PixelSize { PixelSize(width: height, height: width) }
    public var aspectRatio: Double { height == 0 ? 1 : Double(width) / Double(height) }
    public var description: String { "\(width) × \(height)" }
}

/// Size math shared by the renderer and the user interface, so both agree on output
/// dimensions to the pixel.
public enum Geometry {
    /// How much a straightened image must shrink so a rectangle of the original shape
    /// fits inside it with no blank corners.
    public static func straightenScale(width: Double, height: Double, degrees: Double) -> Double {
        guard degrees != 0, width > 0, height > 0 else { return 1 }
        let t = abs(degrees) * .pi / 180
        let c = cos(t), s = sin(t)
        return min(width / (width * c + height * s), height / (width * s + height * c))
    }

    public static func straightenedSize(_ size: PixelSize, degrees: Double) -> PixelSize {
        guard degrees != 0 else { return size }
        let s = straightenScale(width: Double(size.width), height: Double(size.height), degrees: degrees)
        return PixelSize(width: max(1, Int((Double(size.width) * s).rounded(.down))),
                         height: max(1, Int((Double(size.height) * s).rounded(.down))))
    }

    /// The crop in whole pixels, origin at the top left.
    public static func cropPixelRect(_ crop: CropRect, in size: PixelSize) -> (x: Int, y: Int, width: Int, height: Int) {
        let w = Double(size.width), h = Double(size.height)
        let x0 = min(max(Int((crop.x * w).rounded()), 0), size.width - 1)
        let y0 = min(max(Int((crop.y * h).rounded()), 0), size.height - 1)
        let x1 = min(max(Int(((crop.x + crop.width) * w).rounded()), x0 + 1), size.width)
        let y1 = min(max(Int(((crop.y + crop.height) * h).rounded()), y0 + 1), size.height)
        return (x0, y0, x1 - x0, y1 - y0)
    }

    /// Size of the image after each geometry step of `recipe`.
    public static func outputSize(of recipe: EditRecipe, source: PixelSize, includeResize: Bool = true) -> PixelSize {
        var size = source
        for op in recipe.operations {
            switch op {
            case .orient(let o):
                if o.swapsDimensions { size = size.swapped }
            case .straighten(let degrees):
                size = straightenedSize(size, degrees: degrees)
            case .crop(let rect):
                let r = cropPixelRect(rect, in: size)
                size = PixelSize(width: r.width, height: r.height)
            case .border(let b):
                size = b.outputSize(for: size)
            case .resize(let spec):
                if includeResize { size = PixelSize(width: spec.width, height: spec.height) }
            default:
                break
            }
        }
        return size
    }

    /// Fits `size` inside `bounds` keeping its shape (never enlarges past `bounds`).
    public static func fit(_ size: PixelSize, longestSide: Int) -> PixelSize {
        let longest = max(size.width, size.height)
        guard longest > longestSide else { return size }
        let s = Double(longestSide) / Double(longest)
        return PixelSize(width: max(1, Int((Double(size.width) * s).rounded())),
                         height: max(1, Int((Double(size.height) * s).rounded())))
    }
}
