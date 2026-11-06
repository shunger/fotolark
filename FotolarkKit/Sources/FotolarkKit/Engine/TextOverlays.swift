import CoreImage
import CoreText
import Foundation
import ImageIO

public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha].map { CGFloat($0) })!
    }
}

/// A caption or label placed on the photo (after cropping, so it stays where it was put).
public struct TextOverlay: Codable, Equatable, Sendable, Identifiable {
    public enum Alignment: String, Codable, CaseIterable, Sendable { case left, center, right }

    public var id: UUID
    public var text: String
    /// PostScript font name, e.g. "Helvetica-Bold".
    public var fontName: String
    /// Text height as a fraction of the photo's height.
    public var size: Double
    public var color: RGBAColor
    /// Center of the text, normalized 0…1 with the origin top left.
    public var x: Double
    public var y: Double
    public var alignment: Alignment
    public var shadow: Bool
    public var outline: Bool
    public var outlineColor: RGBAColor

    public init(text: String, fontName: String = "Helvetica-Bold", size: Double = 0.07,
                color: RGBAColor = .white, x: Double = 0.5, y: Double = 0.85, alignment: Alignment = .center,
                shadow: Bool = true, outline: Bool = false, outlineColor: RGBAColor = .black, id: UUID = UUID()) {
        self.id = id
        self.text = text
        self.fontName = fontName
        self.size = size
        self.color = color
        self.x = x
        self.y = y
        self.alignment = alignment
        self.shadow = shadow
        self.outline = outline
        self.outlineColor = outlineColor
    }
}

/// A text or logo mark added to exported copies.
public struct Watermark: Codable, Equatable, Hashable, Sendable {
    public enum Position: String, Codable, CaseIterable, Identifiable, Sendable {
        case bottomRight, bottomLeft, topRight, topLeft, center
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .bottomRight: "Bottom right"
            case .bottomLeft: "Bottom left"
            case .topRight: "Top right"
            case .topLeft: "Top left"
            case .center: "Center"
            }
        }
    }

    public var text: String
    /// A logo image file (used instead of the text when set).
    public var logoPath: String?
    public var position: Position
    /// Height of the text, or width of the logo, as a fraction of the photo's shorter side.
    public var size: Double
    public var opacity: Double

    public init(text: String = "© ", logoPath: String? = nil, position: Position = .bottomRight,
                size: Double = 0.05, opacity: Double = 0.6) {
        self.text = text
        self.logoPath = logoPath
        self.position = position
        self.size = size
        self.opacity = opacity
    }
}

public enum TextRenderer {
    /// The text drawn at full opacity on a transparent image, `pixelHeight` tall per line.
    public static func image(text: String, fontName: String, pixelHeight: Double, color: RGBAColor,
                             alignment: TextOverlay.Alignment = .center, shadow: Bool = false,
                             outline: Bool = false, outlineColor: RGBAColor = .black) -> CIImage? {
        guard !text.isEmpty, pixelHeight >= 1 else { return nil }
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(pixelHeight), nil)
        var attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
        var align: CTTextAlignment = alignment == .left ? .left : alignment == .right ? .right : .center
        let setting = withUnsafeBytes(of: &align) { ptr in
            CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: ptr.baseAddress!)
        }
        attrs[NSAttributedString.Key(kCTParagraphStyleAttributeName as String)] = CTParagraphStyleCreate([setting], 1)
        let string = NSAttributedString(string: text, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil)
        let pad = CGFloat(pixelHeight) * 0.3
        let w = Int((fit.width + pad * 2).rounded(.up)), h = Int((fit.height + pad * 2).rounded(.up))
        guard w > 0, h > 0, w < 20000, h < 20000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let path = CGPath(rect: CGRect(x: pad, y: pad, width: fit.width + 1, height: fit.height), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        if shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -pixelHeight * 0.04), blur: CGFloat(pixelHeight) * 0.12,
                          color: CGColor(gray: 0, alpha: 0.75))
        }
        if outline {
            ctx.saveGState()
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineWidth(CGFloat(pixelHeight) * 0.08)
            ctx.setLineJoin(.round)
            // Stroke color comes from the text color attribute, so redraw in the outline color.
            let outlined = NSMutableAttributedString(attributedString: string)
            outlined.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: outlineColor.cgColor,
                                  range: NSRange(location: 0, length: outlined.length))
            outlined.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), value: 16,
                                  range: NSRange(location: 0, length: outlined.length))
            outlined.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: outlineColor.cgColor,
                                  range: NSRange(location: 0, length: outlined.length))
            let of = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(outlined), CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(of, ctx)
            ctx.restoreGState()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}

extension RecipeRenderer {
    static func applyText(_ overlays: [TextOverlay], to image: CIImage) -> CIImage {
        let e = image.extent
        var out = image
        for o in overlays {
            guard let text = TextRenderer.image(text: o.text, fontName: o.fontName, pixelHeight: o.size * e.height,
                                                color: o.color, alignment: o.alignment, shadow: o.shadow,
                                                outline: o.outline, outlineColor: o.outlineColor) else { continue }
            let cx = e.minX + o.x * e.width, cy = e.maxY - o.y * e.height
            let placed = text.transformed(by: CGAffineTransform(translationX: cx - text.extent.width / 2,
                                                                y: cy - text.extent.height / 2))
            out = placed.composited(over: out).cropped(to: e)
        }
        return out
    }

    /// Adds a watermark in a corner (or the middle), inset by 3% of the shorter side.
    public static func applyWatermark(_ w: Watermark, to image: CIImage) -> CIImage {
        let e = image.extent
        let short = min(e.width, e.height)
        var mark: CIImage?
        if let path = w.logoPath, let logo = CIImage(contentsOf: URL(fileURLWithPath: path)) {
            let s = w.size * 2 * short / max(logo.extent.width, 1)
            mark = logo.transformed(by: CGAffineTransform(scaleX: s, y: s))
        } else {
            mark = TextRenderer.image(text: w.text, fontName: "Helvetica-Bold", pixelHeight: w.size * short,
                                      color: .white, shadow: true)
        }
        guard var m = mark?.normalizedToOrigin() else { return image }
        m = m.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: min(max(w.opacity, 0), 1)),
        ])
        let inset = short * 0.03
        let x: CGFloat, y: CGFloat
        switch w.position {
        case .bottomRight: x = e.maxX - inset - m.extent.width; y = e.minY + inset
        case .bottomLeft: x = e.minX + inset; y = e.minY + inset
        case .topRight: x = e.maxX - inset - m.extent.width; y = e.maxY - inset - m.extent.height
        case .topLeft: x = e.minX + inset; y = e.maxY - inset - m.extent.height
        case .center: x = e.midX - m.extent.width / 2; y = e.midY - m.extent.height / 2
        }
        return m.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: image).cropped(to: e)
    }
}
