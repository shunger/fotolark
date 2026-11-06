import CoreGraphics
import CoreImage
import Foundation

/// Several photos arranged on one picture.
public struct CollageSettings: Codable, Equatable, Sendable {
    public enum Layout: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Equal cells in rows and columns.
        case grid
        /// Rows of different heights so each photo keeps its shape, filling the canvas.
        case mosaic
        /// Prints scattered on a table, slightly turned, with white edges.
        case freeform

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .grid: "Grid"
            case .mosaic: "Mosaic"
            case .freeform: "Scattered prints"
            }
        }
    }

    public var layout = Layout.grid
    public var size = PixelSize(width: 3000, height: 2000)
    /// Gap between photos, as a fraction of the shorter side.
    public var spacing = 0.01
    public var background = RGBAColor.white
    /// Changes the scattered arrangement.
    public var seed: UInt64 = 1

    public init() {}

    public static let sizes: [(title: String, size: PixelSize)] = [
        ("Landscape 3:2 (3000 × 2000)", PixelSize(width: 3000, height: 2000)),
        ("Portrait 2:3 (2000 × 3000)", PixelSize(width: 2000, height: 3000)),
        ("Square (3000 × 3000)", PixelSize(width: 3000, height: 3000)),
        ("Widescreen (3840 × 2160)", PixelSize(width: 3840, height: 2160)),
        ("4 × 6 print (1800 × 1200)", PixelSize(width: 1800, height: 1200)),
        ("8 × 10 print (3000 × 2400)", PixelSize(width: 3000, height: 2400)),
    ]
}

/// Where one photo goes: a rectangle (pixels, top-left origin) and a turn in degrees.
public struct CollagePlacement: Equatable, Sendable {
    public var rect: CGRect
    public var degrees: Double
    /// Freeform prints get a white edge and a shadow.
    public var framed: Bool
}

public enum CollageMaker {
    /// Places photos of the given shapes (width ÷ height).
    public static func placements(aspects: [Double], settings: CollageSettings) -> [CollagePlacement] {
        let n = aspects.count
        guard n > 0 else { return [] }
        let W = CGFloat(settings.size.width), H = CGFloat(settings.size.height)
        let gap = CGFloat(settings.spacing) * min(W, H)
        switch settings.layout {
        case .grid:
            // The column count whose cells are closest to the photos' typical shape.
            let typical = aspects.sorted()[n / 2]
            var best = (cols: 1, score: Double.infinity)
            for cols in 1...n {
                let rows = Int(ceil(Double(n) / Double(cols)))
                let cw = (W - gap * CGFloat(cols + 1)) / CGFloat(cols)
                let ch = (H - gap * CGFloat(rows + 1)) / CGFloat(rows)
                guard cw > 0, ch > 0 else { continue }
                let score = abs(log(Double(cw / ch) / typical)) + Double(rows * cols - n) * 0.15
                if score < best.score { best = (cols, score) }
            }
            let cols = best.cols, rows = Int(ceil(Double(n) / Double(cols)))
            let cw = (W - gap * CGFloat(cols + 1)) / CGFloat(cols)
            let ch = (H - gap * CGFloat(rows + 1)) / CGFloat(rows)
            return (0..<n).map { i in
                let r = i / cols, c = i % cols
                // Center a short last row.
                let inRow = r == rows - 1 ? n - r * cols : cols
                let offset = CGFloat(cols - inRow) * (cw + gap) / 2
                return CollagePlacement(rect: CGRect(x: gap + offset + CGFloat(c) * (cw + gap), y: gap + CGFloat(r) * (ch + gap),
                                                     width: cw, height: ch), degrees: 0, framed: false)
            }

        case .mosaic:
            // Split the photos into rows (in order) so that, with each row scaled to the full
            // width, the rows together come closest to the canvas height.
            var bestRows: [[Int]] = [Array(0..<n)]
            var bestError = CGFloat.infinity
            for rowCount in 1...n {
                let rows = split(aspects, into: rowCount)
                let heights = rows.map { row -> CGFloat in
                    let sum = row.reduce(0.0) { $0 + aspects[$1] }
                    return (W - gap * CGFloat(row.count + 1)) / CGFloat(sum)
                }
                let total = heights.reduce(0, +) + gap * CGFloat(rows.count + 1)
                let err = abs(total - H)
                if err < bestError { bestError = err; bestRows = rows }
            }
            // Then stretch the row heights to fill the canvas exactly (photos are filled
            // into their cells, so a small stretch only trims a little).
            let natural = bestRows.map { row -> CGFloat in
                (W - gap * CGFloat(row.count + 1)) / CGFloat(row.reduce(0.0) { $0 + aspects[$1] })
            }
            let scale = (H - gap * CGFloat(bestRows.count + 1)) / natural.reduce(0, +)
            var out = Array(repeating: CollagePlacement(rect: .zero, degrees: 0, framed: false), count: n)
            var y = gap
            for (row, h0) in zip(bestRows, natural) {
                let h = h0 * scale
                var x = gap
                let sum = row.reduce(0.0) { $0 + aspects[$1] }
                for i in row {
                    let w = (W - gap * CGFloat(row.count + 1)) * CGFloat(aspects[i] / sum)
                    out[i] = CollagePlacement(rect: CGRect(x: x, y: y, width: w, height: h), degrees: 0, framed: false)
                    x += w + gap
                }
                y += h + gap
            }
            return out

        case .freeform:
            // A loose grid with each print nudged and turned a little.
            var rng = SeededGenerator(seed: settings.seed)
            let cols = max(1, Int(ceil(sqrt(Double(n) * Double(W / H)))))
            let rows = Int(ceil(Double(n) / Double(cols)))
            let cellW = W / CGFloat(cols), cellH = H / CGFloat(rows)
            return (0..<n).map { i in
                let r = i / cols, c = i % cols
                let a = CGFloat(aspects[i])
                // Prints a bit bigger than their cell, so they overlap like a real pile.
                var w = cellW * 1.05, h = w / a
                if h > cellH * 1.05 { h = cellH * 1.05; w = h * a }
                let jx = CGFloat(Double.random(in: -0.12...0.12, using: &rng)) * cellW
                let jy = CGFloat(Double.random(in: -0.12...0.12, using: &rng)) * cellH
                let cx = (CGFloat(c) + 0.5) * cellW + jx, cy = (CGFloat(r) + 0.5) * cellH + jy
                return CollagePlacement(rect: CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h),
                                        degrees: Double.random(in: -9...9, using: &rng), framed: true)
            }
        }
    }

    /// Splits in order into `count` rows with sums of aspect as even as possible.
    static func split(_ aspects: [Double], into count: Int) -> [[Int]] {
        let total = aspects.reduce(0, +)
        let target = total / Double(count)
        var rows: [[Int]] = []
        var current: [Int] = []
        var sum = 0.0
        for (i, a) in aspects.enumerated() {
            let remainingRows = count - rows.count
            let remainingItems = aspects.count - i
            // Close the row when adding this photo overshoots more than leaving it out
            // (or when every remaining photo is needed for a row of its own).
            let mustClose = remainingItems == remainingRows - 1
            if !current.isEmpty && remainingRows > 1
                && (mustClose || abs(sum + a - target) > abs(sum - target)) {
                rows.append(current)
                current = []
                sum = 0
            }
            current.append(i)
            sum += a
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// The finished collage.
    public static func render(_ items: [PageItem], settings: CollageSettings, engine: EditEngine) -> CIImage? {
        let W = CGFloat(settings.size.width), H = CGFloat(settings.size.height)
        // Photos at about the size they'll appear.
        var images: [CIImage] = []
        for item in items {
            let longest = Int(max(W, H) / CGFloat(max(1, Int(sqrt(Double(items.count))))) * 1.3)
            guard let preview = try? ImageLoader.loadPreview(item.url, maxPixelSize: max(longest, 256)) else { continue }
            images.append(RecipeRenderer.apply(item.recipe.withoutResize, to: preview))
        }
        guard !images.isEmpty else { return nil }
        let aspects = images.map { Double($0.extent.width / $0.extent.height) }
        let places = placements(aspects: aspects, settings: settings)
        let c = settings.background
        var out = CIImage(color: CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1,
                                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
        for (image, place) in zip(images, places) {
            // Top-left rectangles to Core Image's bottom-left space.
            let rect = CGRect(x: place.rect.minX, y: H - place.rect.maxY, width: place.rect.width, height: place.rect.height)
            var photo = fill(image, into: rect)
            if place.framed {
                let edge = max(rect.width, rect.height) * 0.035
                let frame = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: rect.insetBy(dx: -edge, dy: -edge))
                photo = photo.composited(over: frame)
                let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                    .cropped(to: frame.extent.offsetBy(dx: edge * 0.25, dy: -edge * 0.35))
                    .applyingGaussianBlur(sigma: Double(edge) * 0.6)
                photo = photo.composited(over: shadow)
            }
            if place.degrees != 0 {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                photo = photo.transformed(by: CGAffineTransform(translationX: center.x, y: center.y)
                    .rotated(by: -CGFloat(place.degrees) * .pi / 180)
                    .translatedBy(x: -center.x, y: -center.y))
            }
            out = photo.composited(over: out)
        }
        return out.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    }

    /// `image` scaled to cover `rect`, centered and cropped to it.
    static func fill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        let s = max(rect.width / e.width, rect.height / e.height)
        let scaled = image.samplingLinear().transformed(by: CGAffineTransform(scaleX: s, y: s))
        let se = scaled.extent
        return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - se.midX, y: rect.midY - se.midY))
            .cropped(to: rect)
    }
}
