import CoreGraphics
import Foundation

/// Converts between points on the edited photo as shown (after turning, straightening
/// and cropping) and points on the original photo. Spot edits such as red-eye and
/// healing are stored on the original, so they stay put if the crop changes later.
///
/// All points are normalized 0…1 with the origin at the top left.
public enum PointMapping {
    /// Original → shown. Returns nil if the point was cropped away.
    public static func displayPoint(fromSource p: CGPoint, recipe: EditRecipe, sourceSize: PixelSize) -> CGPoint? {
        var point = p
        var size = sourceSize
        for op in recipe.operations {
            switch op {
            case .orient(let o):
                if o.mirrored { point = CGPoint(x: 1 - point.x, y: point.y) }
                for _ in 0..<o.quarterTurns { point = CGPoint(x: 1 - point.y, y: point.x) }
                if o.swapsDimensions { size = size.swapped }
            case .straighten(let degrees):
                let out = Geometry.straightenedSize(size, degrees: degrees)
                point = rotate(point, from: size, to: out, degrees: degrees)
                size = out
            case .crop(let c):
                point = CGPoint(x: (point.x - c.x) / c.width, y: (point.y - c.y) / c.height)
                let r = Geometry.cropPixelRect(c, in: size)
                size = PixelSize(width: r.width, height: r.height)
            default:
                break
            }
        }
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return point
    }

    /// Shown → original.
    public static func sourcePoint(fromDisplay p: CGPoint, recipe: EditRecipe, sourceSize: PixelSize) -> CGPoint {
        // Sizes going into each geometry step, so the steps can be undone in reverse.
        var steps: [(EditOperation, PixelSize)] = []
        var size = sourceSize
        for op in recipe.operations {
            switch op {
            case .orient(let o):
                steps.append((op, size))
                if o.swapsDimensions { size = size.swapped }
            case .straighten(let d):
                steps.append((op, size))
                size = Geometry.straightenedSize(size, degrees: d)
            case .crop(let c):
                steps.append((op, size))
                let r = Geometry.cropPixelRect(c, in: size)
                size = PixelSize(width: r.width, height: r.height)
            default:
                break
            }
        }
        var point = p
        for (op, inputSize) in steps.reversed() {
            switch op {
            case .orient(let o):
                for _ in 0..<o.quarterTurns { point = CGPoint(x: point.y, y: 1 - point.x) }
                if o.mirrored { point = CGPoint(x: 1 - point.x, y: point.y) }
            case .straighten(let degrees):
                let out = Geometry.straightenedSize(inputSize, degrees: degrees)
                point = rotate(point, from: out, to: inputSize, degrees: -degrees)
            case .crop(let c):
                point = CGPoint(x: c.x + point.x * c.width, y: c.y + point.y * c.height)
            default:
                break
            }
        }
        return point
    }

    /// Turns a point about the image center by `degrees` clockwise, moving it from an
    /// image of size `from` to one of size `to` that shares the same center.
    static func rotate(_ p: CGPoint, from: PixelSize, to: PixelSize, degrees: Double) -> CGPoint {
        let t = degrees * .pi / 180
        // Pixels, relative to the center, y pointing down.
        let x = (p.x - 0.5) * Double(from.width)
        let y = (p.y - 0.5) * Double(from.height)
        let rx = x * cos(t) - y * sin(t)
        let ry = x * sin(t) + y * cos(t)
        return CGPoint(x: rx / Double(to.width) + 0.5, y: ry / Double(to.height) + 0.5)
    }
}
