import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Paper to print or make PDF pages on.
public enum PaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case letter, a4, legal, photo4x6, photo5x7, photo8x10, a3, tabloid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .letter: "US Letter"
        case .a4: "A4"
        case .legal: "US Legal"
        case .photo4x6: "4 × 6 in photo paper"
        case .photo5x7: "5 × 7 in photo paper"
        case .photo8x10: "8 × 10 in photo paper"
        case .a3: "A3"
        case .tabloid: "Tabloid (11 × 17 in)"
        }
    }

    /// Portrait size in points (72 per inch).
    public var points: CGSize {
        switch self {
        case .letter: CGSize(width: 612, height: 792)
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .legal: CGSize(width: 612, height: 1008)
        case .photo4x6: CGSize(width: 288, height: 432)
        case .photo5x7: CGSize(width: 360, height: 504)
        case .photo8x10: CGSize(width: 576, height: 720)
        case .a3: CGSize(width: 841.89, height: 1190.55)
        case .tabloid: CGSize(width: 792, height: 1224)
        }
    }

    /// Letter in the US and Canada, A4 elsewhere.
    public static var regionalDefault: PaperSize {
        ["US", "CA", "MX", "PH"].contains(Locale.current.region?.identifier ?? "") ? .letter : .a4
    }
}

/// How big each photo prints.
public enum PrintSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case fullPage, wallet, size4x6, size5x7, size8x10

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fullPage: "Full page"
        case .wallet: "Wallet (2.5 × 3.5 in)"
        case .size4x6: "4 × 6 in"
        case .size5x7: "5 × 7 in"
        case .size8x10: "8 × 10 in"
        }
    }

    /// Short side × long side, in points; nil for the full page.
    public var points: CGSize? {
        switch self {
        case .fullPage: nil
        case .wallet: CGSize(width: 180, height: 252)
        case .size4x6: CGSize(width: 288, height: 432)
        case .size5x7: CGSize(width: 360, height: 504)
        case .size8x10: CGSize(width: 576, height: 720)
        }
    }
}

public struct PageSettings: Codable, Equatable, Sendable {
    public var paper = PaperSize.regionalDefault
    public var landscape = false
    public var printSize = PrintSize.fullPage
    /// Fill each cell edge to edge (cropping) instead of fitting the whole photo.
    public var fill = false
    /// Fill each page with copies of one photo (for example a sheet of wallets).
    public var repeatEach = false
    /// Turn photos sideways when that makes them print bigger.
    public var autoRotate = true
    /// Blank edge around the page, in inches.
    public var margin = 0.25
    /// Contact sheets: photos per row.
    public var columns = 5
    /// Contact sheets: names under the photos.
    public var showNames = true

    public init() {}

    public var pageSize: CGSize {
        let p = paper.points
        return landscape ? CGSize(width: p.height, height: p.width) : p
    }

    var printable: CGRect {
        let m = margin * 72
        return CGRect(origin: .zero, size: pageSize).insetBy(dx: m, dy: m)
    }
}

/// Where things go on a page. Rectangles are in points with the origin at the top left.
public enum PageLayout {
    /// Cells for prints of `settings.printSize` on one page, as many as fit, centered.
    public static func printCells(_ settings: PageSettings) -> [CGRect] {
        let area = settings.printable
        guard let print = settings.printSize.points else { return [area] }
        // Try the print upright and sideways; keep whichever fits more.
        var best: [CGRect] = []
        for size in [print, CGSize(width: print.height, height: print.width)] {
            let cols = Int((area.width + 0.5) / size.width), rows = Int((area.height + 0.5) / size.height)
            guard cols * rows > best.count else { continue }
            let used = CGSize(width: CGFloat(cols) * size.width, height: CGFloat(rows) * size.height)
            let origin = CGPoint(x: area.minX + (area.width - used.width) / 2, y: area.minY + (area.height - used.height) / 2)
            best = (0..<rows).flatMap { r in
                (0..<cols).map { c in
                    CGRect(x: origin.x + CGFloat(c) * size.width, y: origin.y + CGFloat(r) * size.height,
                           width: size.width, height: size.height)
                }
            }
        }
        // A print bigger than the paper: shrink it to the page.
        return best.isEmpty ? [area] : best
    }

    /// Thumbnail cells on a contact sheet page, below a heading line.
    public static func contactCells(_ settings: PageSettings, headerHeight: CGFloat = 28,
                                    captionHeight: CGFloat? = nil) -> [CGRect] {
        let area = settings.printable
        let cols = max(1, settings.columns)
        let gap: CGFloat = 8
        let caption = captionHeight ?? (settings.showNames ? 14 : 0)
        let cellW = (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = cellW + caption
        let top = area.minY + headerHeight
        let rows = max(1, Int((area.maxY - top + gap) / (cellH + gap)))
        return (0..<rows).flatMap { r in
            (0..<cols).map { c in
                CGRect(x: area.minX + CGFloat(c) * (cellW + gap), y: top + CGFloat(r) * (cellH + gap),
                       width: cellW, height: cellH)
            }
        }
    }

    /// Where a photo of `aspect` (width ÷ height) goes inside `cell`: the whole photo
    /// (fit) or the cell filled. Also says whether to turn it a quarter turn.
    public static func place(aspect: Double, in cell: CGRect, fill: Bool, autoRotate: Bool) -> (rect: CGRect, turned: Bool) {
        let cellAspect = Double(cell.width / cell.height)
        let turned = autoRotate && (aspect > 1) != (cellAspect > 1) && abs(aspect - 1) > 0.05 && abs(cellAspect - 1) > 0.05
        let a = turned ? 1 / aspect : aspect
        if fill { return (cell, turned) }
        var w = cell.width, h = cell.height
        if a > cellAspect { h = w / CGFloat(a) } else { w = h * CGFloat(a) }
        return (CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h), turned)
    }
}

/// One photo to put on a page, with its edits.
public struct PageItem: Sendable {
    public var url: URL
    public var recipe: EditRecipe

    public init(url: URL, recipe: EditRecipe) {
        self.url = url
        self.recipe = recipe
    }
}

/// Makes PDF pages: prints, contact sheets and plain photo PDFs.
public enum PDFComposer {
    public enum Kind: Sendable {
        /// Photos at a print size, one or more per page.
        case prints
        /// Thumbnails with names.
        case contactSheet(title: String)
    }

    /// Photos for each page (prints, or a contact sheet), in order.
    public static func pages(count: Int, kind: Kind, settings: PageSettings) -> [[Int]] {
        guard count > 0 else { return [] }
        switch kind {
        case .prints:
            let perPage = PageLayout.printCells(settings).count
            if settings.repeatEach { return (0..<count).map { Array(repeating: $0, count: perPage) } }
            return stride(from: 0, to: count, by: perPage).map { Array($0..<min($0 + perPage, count)) }
        case .contactSheet:
            let perPage = PageLayout.contactCells(settings).count
            return stride(from: 0, to: count, by: perPage).map { Array($0..<min($0 + perPage, count)) }
        }
    }

    /// The PDF. `dpi` sets how much detail each photo keeps (300 prints well; lower makes a
    /// quick preview). `pageLimit` stops early (for a preview). Reports progress per page.
    public static func make(_ items: [PageItem], kind: Kind, settings: PageSettings, engine: EditEngine,
                            dpi: Double = 300, pageLimit: Int? = nil,
                            progress: (Int, Int) -> Void = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: settings.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw FotolarkError.cannotEncode("PDF")
        }
        var pages = pages(count: items.count, kind: kind, settings: settings)
        if let pageLimit { pages = Array(pages.prefix(pageLimit)) }
        let cells: [CGRect]
        switch kind {
        case .prints: cells = PageLayout.printCells(settings)
        case .contactSheet: cells = PageLayout.contactCells(settings)
        }
        let pageHeight = settings.pageSize.height
        // Each photo is rendered once, even when repeated on its page.
        var cache: [Int: CGImage] = [:]

        for (pageIndex, page) in pages.enumerated() {
            if isCancelled() { break }
            ctx.beginPDFPage(nil)
            if case .contactSheet(let title) = kind {
                let heading = pages.count > 1 ? "\(title) · page \(pageIndex + 1) of \(pages.count)" : title
                drawText(heading, in: CGRect(x: settings.printable.minX, y: settings.printable.minY,
                                             width: settings.printable.width, height: 20),
                         size: 11, bold: true, ctx: ctx, pageHeight: pageHeight, centered: false)
            }
            for (slot, index) in page.enumerated() where slot < cells.count {
                var cell = cells[slot]
                var caption: CGRect?
                if case .contactSheet = kind, settings.showNames {
                    caption = CGRect(x: cell.minX, y: cell.maxY - 13, width: cell.width, height: 13)
                    cell.size.height -= 14
                }
                let item = items[index]
                let image: CGImage?
                if let cached = cache[index] {
                    image = cached
                } else {
                    let longestPoints = max(cell.width, cell.height)
                    image = renderPhoto(item, longestSide: Int(longestPoints / 72 * dpi), engine: engine)
                    if settings.repeatEach, let image { cache = [index: image] }
                }
                if let image {
                    let aspect = Double(image.width) / Double(image.height)
                    let fill: Bool, rotate: Bool
                    if case .contactSheet = kind { fill = false; rotate = false } else { fill = settings.fill; rotate = settings.autoRotate }
                    let placed = PageLayout.place(aspect: aspect, in: cell, fill: fill, autoRotate: rotate)
                    draw(image, in: placed.rect, turned: placed.turned, fill: fill, ctx: ctx, pageHeight: pageHeight)
                }
                if let caption {
                    drawText(item.url.lastPathComponent, in: caption, size: 7, bold: false, ctx: ctx,
                             pageHeight: pageHeight, centered: true)
                }
            }
            ctx.endPDFPage()
            progress(pageIndex + 1, pages.count)
        }
        ctx.closePDF()
        return data as Data
    }

    /// The edited photo at about `longestSide` pixels, as a JPEG-backed image (so the PDF
    /// stays a sensible size).
    static func renderPhoto(_ item: PageItem, longestSide: Int, engine: EditEngine) -> CGImage? {
        guard let preview = try? ImageLoader.loadPreview(item.url, maxPixelSize: max(longestSide, 64)) else { return nil }
        let edited = RecipeRenderer.apply(item.recipe.withoutResize, to: preview)
        guard let cg = engine.makeCGImage(edited, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let jpeg = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { return cg }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: jpeg as CFData),
              let backed = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent) else { return cg }
        return backed
    }

    /// Draws `image` into `rect` (top-left page coordinates), turned a quarter turn if
    /// asked, cropped to the rectangle when filling.
    static func draw(_ image: CGImage, in rect: CGRect, turned: Bool, fill: Bool, ctx: CGContext, pageHeight: CGFloat) {
        let r = CGRect(x: rect.minX, y: pageHeight - rect.maxY, width: rect.width, height: rect.height)
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.midX, y: r.midY)
        if turned { ctx.rotate(by: -.pi / 2) }
        // The space the image is drawn in, before turning.
        let space = turned ? CGSize(width: r.height, height: r.width) : r.size
        let a = CGFloat(image.width) / CGFloat(image.height)
        var w = space.width, h = space.height
        if fill {
            if a > w / h { w = h * a } else { h = w / a }
        } else {
            if a > w / h { h = w / a } else { w = h * a }
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }

    static func drawText(_ text: String, in rect: CGRect, size: CGFloat, bold: Bool, ctx: CGContext,
                         pageHeight: CGFloat, centered: Bool) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        // Shorten long names with "…" in the middle.
        let fitted = CTLineCreateTruncatedLine(line, Double(rect.width), .middle,
                                               CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs)))
            ?? line
        let width = CGFloat(CTLineGetTypographicBounds(fitted, nil, nil, nil))
        let x = centered ? rect.midX - width / 2 : rect.minX
        ctx.saveGState()
        ctx.textPosition = CGPoint(x: x, y: pageHeight - rect.maxY + (rect.height - size) / 2 + 2)
        CTLineDraw(fitted, ctx)
        ctx.restoreGState()
    }
}
