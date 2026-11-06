import Foundation

/// A point on a tone curve, 0…1 in both directions (input → output).
public struct CurvePoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

/// A smooth tone curve through its points (monotone cubic, so it never overshoots).
public struct ToneCurve: Codable, Equatable, Sendable {
    public var points: [CurvePoint]

    public init(points: [CurvePoint] = ToneCurve.straight.points) {
        self.points = points
    }

    public static let straight = ToneCurve(points: [CurvePoint(0, 0), CurvePoint(1, 1)])

    public var isStraight: Bool {
        sortedPoints.allSatisfy { abs($0.x - $0.y) < 0.0005 }
    }

    var sortedPoints: [CurvePoint] {
        var p = points.sorted { $0.x < $1.x }
        if p.first.map({ $0.x > 0 }) ?? true { p.insert(CurvePoint(0, p.first?.y ?? 0), at: 0) }
        if p.last.map({ $0.x < 1 }) ?? true { p.append(CurvePoint(1, p.last?.y ?? 1)) }
        return p
    }

    /// Output for input `x` (Fritsch–Carlson monotone cubic interpolation).
    public func value(at x: Double) -> Double {
        let p = sortedPoints
        guard p.count > 1 else { return x }
        if x <= p[0].x { return clamp(p[0].y) }
        if x >= p[p.count - 1].x { return clamp(p[p.count - 1].y) }
        let n = p.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-9) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0..<(n - 1) where d[i] == 0 {
            m[i] = 0
            m[i + 1] = 0
        }
        for i in 0..<(n - 1) where d[i] != 0 {
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]
                m[i + 1] = t * b * d[i]
            }
        }
        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = p[k + 1].x - p[k].x
        let t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        let y = (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
        return clamp(y)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

/// Curves for all channels together and for red, green and blue.
public struct Curves: Codable, Equatable, Sendable {
    public var rgb = ToneCurve.straight
    public var red = ToneCurve.straight
    public var green = ToneCurve.straight
    public var blue = ToneCurve.straight

    public init() {}

    public var isIdentity: Bool { rgb.isStraight && red.isStraight && green.isStraight && blue.isStraight }
}

/// Input and output levels, in gamma-encoded 0…1 values.
public struct ToneLevels: Codable, Equatable, Sendable {
    public var inputBlack = 0.0
    public var inputWhite = 1.0
    /// Midtone brightness: above 1 brightens, below 1 darkens.
    public var gamma = 1.0
    public var outputBlack = 0.0
    public var outputWhite = 1.0

    public init() {}

    public var isIdentity: Bool { self == ToneLevels() }

    public func value(at x: Double) -> Double {
        let range = max(inputWhite - inputBlack, 0.01)
        let t = min(max((x - inputBlack) / range, 0), 1)
        let g = pow(t, 1 / max(gamma, 0.05))
        return outputBlack + g * (outputWhite - outputBlack)
    }
}

/// Hue, saturation and lightness changes for eight color ranges ("selective color").
public struct ColorRanges: Codable, Equatable, Sendable {
    public enum Band: Int, Codable, CaseIterable, Identifiable, Sendable {
        case red, orange, yellow, green, aqua, blue, purple, magenta

        public var id: Int { rawValue }
        public var title: String {
            ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue]
        }
        /// Center hue in degrees.
        public var hue: Double { [0, 30, 60, 120, 180, 225, 270, 315][rawValue] }
    }

    public struct Adjustment: Codable, Equatable, Sendable {
        /// −1…+1: shifts the hue up to 30° either way.
        public var hue = 0.0
        public var saturation = 0.0
        public var lightness = 0.0
        public init() {}
    }

    /// One entry per band, in `Band` order.
    public var bands: [Adjustment] = Array(repeating: Adjustment(), count: Band.allCases.count)

    public init() {}

    public var isIdentity: Bool { bands.allSatisfy { $0 == Adjustment() } }

    public subscript(band: Band) -> Adjustment {
        get { bands.indices.contains(band.rawValue) ? bands[band.rawValue] : Adjustment() }
        set {
            while bands.count < Band.allCases.count { bands.append(Adjustment()) }
            bands[band.rawValue] = newValue
        }
    }

    /// Applies the bands to one gamma-encoded RGB color.
    public func apply(r: Double, g: Double, b: Double) -> (Double, Double, Double) {
        var (h, s, l) = Self.rgbToHSL(r, g, b)
        guard s > 0.0001 else { return (r, g, b) }
        var dh = 0.0, ds = 0.0, dl = 0.0, total = 0.0
        for band in Band.allCases {
            // Each band reaches 45° to either side of its center, fading out smoothly.
            var dist = abs(h - band.hue)
            if dist > 180 { dist = 360 - dist }
            let w = dist >= 45 ? 0 : 0.5 * (1 + cos(.pi * dist / 45))
            guard w > 0 else { continue }
            let a = self[band]
            dh += w * a.hue * 30
            ds += w * a.saturation
            dl += w * a.lightness
            total += w
        }
        guard total > 0 else { return (r, g, b) }
        // Weights already fall off with distance; normalizing keeps overlaps from doubling.
        let norm = max(total, 1)
        h = (h + dh / norm).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        let sd = ds / norm
        s = sd >= 0 ? s + (1 - s) * sd * s : s * (1 + sd)
        // Lightness changes count more on saturated colors so grays stay put.
        l = min(max(l + dl / norm * 0.5 * s, 0), 1)
        return Self.hslToRGB(h, min(max(s, 0), 1), l)
    }

    static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return (h, s, l)
    }

    static func hslToRGB(_ h: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func hue(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let hh = h / 360
        return (hue(hh + 1 / 3), hue(hh), hue(hh - 1 / 3))
    }
}

extension EditRecipe {
    public var toneLevels: ToneLevels {
        if case .levels(let l) = operation(.levels) { return l }
        return ToneLevels()
    }

    public var curves: Curves {
        if case .curves(let c) = operation(.curves) { return c }
        return Curves()
    }

    public var colorRanges: ColorRanges {
        if case .colorRanges(let r) = operation(.colorRanges) { return r }
        return ColorRanges()
    }
}
