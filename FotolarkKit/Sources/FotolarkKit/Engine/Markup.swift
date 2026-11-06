import CoreGraphics
import CoreImage
import Foundation

// MARK: - Borders and frames

/// A border around the finished photo.
public struct Border: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Identifiable, Sendable {
        /// The same width all round.
        case plain
        /// Rounded photo corners inside the border.
        case rounded
        /// An instant-print frame: narrow sides, a deep strip at the bottom.
        case polaroid

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .plain: "Plain"
            case .rounded: "Rounded"
            case .polaroid: "Instant Print"
            }
        }
    }

    public var style: Style
    /// Border width as a fraction of the photo's shorter side.
    public var width: Double
    public var color: RGBAColor
    /// Rounded style: corner radius as a fraction of the shorter side.
    public var cornerRadius: Double

    public init(style: Style = .plain, width: Double = 0.04, color: RGBAColor = .white, cornerRadius: Double = 0.06) {
        self.style = style
        self.width = width
        self.color = color
        self.cornerRadius = cornerRadius
    }

    /// Pixels added on each side of a photo of `size`.
    public func insets(for size: PixelSize) -> (left: Int, right: Int, top: Int, bottom: Int) {
        let b = Int((width * Double(min(size.width, size.height))).rounded())
        switch style {
        case .plain, .rounded: return (b, b, b, b)
        case .polaroid:
            let side = max(b, 1)
            return (side, side, side, side * 4)
        }
    }

    public func outputSize(for size: PixelSize) -> PixelSize {
        let i = insets(for: size)
        return PixelSize(width: size.width + i.left + i.right, height: size.height + i.top + i.bottom)
    }
}

// MARK: - Shapes and arrows

/// A simple shape drawn on the photo, for pointing things out (for example on a screenshot).
public struct MarkupShape: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case arrow, line, rectangle, ellipse, highlight

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .arrow: "Arrow"
            case .line: "Line"
            case .rectangle: "Box"
            case .ellipse: "Circle"
            case .highlight: "Highlight"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Where the drag started and ended, normalized on the cropped photo (top-left origin).
    public var start: CurvePoint
    public var end: CurvePoint
    public var color: RGBAColor
    /// Line thickness as a fraction of the photo's longest side.
    public var lineWidth: Double

    public init(id: UUID = UUID(), kind: Kind, start: CurvePoint, end: CurvePoint,
                color: RGBAColor = RGBAColor(red: 0.95, green: 0.15, blue: 0.1), lineWidth: Double = 0.006) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.lineWidth = lineWidth
    }
}

extension RecipeRenderer {
    static func applyMarkup(_ shapes: [MarkupShape], to image: CIImage) -> CIImage {
        let e = image.extent
        var out = image
        for shape in shapes {
            guard let drawn = draw(shape, in: e) else { continue }
            out = drawn.composited(over: out).cropped(to: e)
        }
        return out
    }

    /// Draws one shape into a bitmap just big enough for it.
    static func draw(_ s: MarkupShape, in e: CGRect) -> CIImage? {
        let longest = max(e.width, e.height)
        let lw = max(1, s.lineWidth * longest)
        let a = CGPoint(x: s.start.x * e.width, y: (1 - s.start.y) * e.height)
        let b = CGPoint(x: s.end.x * e.width, y: (1 - s.end.y) * e.height)
        let head = max(lw * 4.5, longest * 0.015)
        let pad = (s.kind == .arrow ? head : 0) + lw * 2 + 2
        let bounds = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -pad, dy: -pad)
            .intersection(CGRect(origin: .zero, size: e.size))
            .integral
        guard bounds.width >= 1, bounds.height >= 1,
              let ctx = CGContext(data: nil, width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
        let c = s.color
        let color = CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))

        switch s.kind {
        case .line:
            ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
        case .arrow:
            let angle = atan2(b.y - a.y, b.x - a.x)
            let len = hypot(b.x - a.x, b.y - a.y)
            let h = min(head, len * 0.6)
            // The shaft stops at the head's base so the point stays sharp.
            let base = CGPoint(x: b.x - cos(angle) * h * 0.8, y: b.y - sin(angle) * h * 0.8)
            ctx.move(to: a); ctx.addLine(to: base); ctx.strokePath()
            let spread = 0.45
            ctx.move(to: b)
            ctx.addLine(to: CGPoint(x: b.x - cos(angle - spread) * h, y: b.y - sin(angle - spread) * h))
            ctx.addLine(to: CGPoint(x: b.x - cos(angle + spread) * h, y: b.y - sin(angle + spread) * h))
            ctx.closePath()
            ctx.fillPath()
        case .rectangle:
            ctx.stroke(rect)
        case .ellipse:
            ctx.strokeEllipse(in: rect)
        case .highlight:
            // A see-through marker box.
            ctx.setFillColor(CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: min(c.alpha, 0.35)))
            ctx.fill(rect)
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: e.minX + bounds.minX,
                                                                      y: e.minY + bounds.minY))
    }

    static func applyBorder(_ border: Border, to image: CIImage) -> CIImage {
        let e = image.extent
        let size = PixelSize(width: Int(e.width.rounded()), height: Int(e.height.rounded()))
        let i = border.insets(for: size)
        let out = border.outputSize(for: size)
        let canvasRect = CGRect(x: 0, y: 0, width: out.width, height: out.height)
        let c = border.color
        let fill = CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: canvasRect)
        // Photo moved in from the left and up from the bottom inset.
        var photo = image.transformed(by: CGAffineTransform(translationX: CGFloat(i.left) - e.minX,
                                                            y: CGFloat(i.bottom) - e.minY))
        if border.style == .rounded, border.cornerRadius > 0 {
            let r = border.cornerRadius * Double(min(size.width, size.height))
            if let shape = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: photo.extent), "inputRadius": r,
                "inputColor": CIColor(red: 1, green: 1, blue: 1),
            ])?.outputImage {
                photo = photo.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: fill, kCIInputMaskImageKey: shape,
                ]).cropped(to: photo.extent)
            }
        }
        return photo.composited(over: fill).cropped(to: canvasRect)
    }
}

// MARK: - Versions

/// A named copy of a photo's edits, to come back to or compare.
public struct EditVersion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    public var recipe: EditRecipe

    public init(id: UUID = UUID(), name: String, created: Date = Date(), recipe: EditRecipe) {
        self.id = id
        self.name = name
        self.created = created
        self.recipe = recipe
    }
}
