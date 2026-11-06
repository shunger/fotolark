import Foundation

/// One step in an edit recipe. Operations are replayed in order through Core Image.
public enum EditOperation: Equatable, Sendable {
    /// One-click "Magic fix": the filter chain Core Image suggested for this photo, frozen
    /// at the moment it was applied so replaying the recipe always gives the same result.
    case magicFix(FilterChain)
    /// One-click contrast stretch.
    case autoContrast(Levels)
    /// One-click color-cast removal.
    case autoColor(ChannelGains)
    /// Neutral point picked by clicking something that should be gray.
    case whiteBalance(ChannelGains)
    /// Light and color sliders.
    case adjust(Adjustments)
    /// Input and output levels.
    case levels(ToneLevels)
    /// Tone curves.
    case curves(Curves)
    /// Hue, saturation and lightness per color range.
    case colorRanges(ColorRanges)
    /// 90° turns and flips.
    case orient(Orientation)
    /// Straighten by an angle in degrees (positive = clockwise). The result is cropped to
    /// the largest rectangle of the same shape, so no blank corners show.
    case straighten(degrees: Double)
    /// Crop, in normalized coordinates of the image coming into this step.
    case crop(CropRect)
    /// Final output size in pixels. Applied on export, not in the on-screen preview.
    case resize(ResizeSpec)

    /// The kind of an operation; a recipe holds at most one operation of each kind.
    public enum Kind: String, Codable, CaseIterable, Sendable, Comparable {
        case magicFix, autoContrast, autoColor, whiteBalance, adjust, levels, curves, colorRanges, orient, straighten, crop, resize

        /// Canonical position in a recipe: tone and color first, then geometry, then size.
        var order: Int { Kind.allCases.firstIndex(of: self)! }

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.order < rhs.order }

        public var isGeometry: Bool {
            switch self {
            case .orient, .straighten, .crop, .resize: true
            default: false
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .magicFix: .magicFix
        case .autoContrast: .autoContrast
        case .autoColor: .autoColor
        case .whiteBalance: .whiteBalance
        case .adjust: .adjust
        case .levels: .levels
        case .curves: .curves
        case .colorRanges: .colorRanges
        case .orient: .orient
        case .straighten: .straighten
        case .crop: .crop
        case .resize: .resize
        }
    }

    /// True when the operation would not change the image (e.g. all sliders at zero).
    public var isIdentity: Bool {
        switch self {
        case .magicFix(let chain): chain.steps.isEmpty
        case .autoContrast(let levels): levels == .identity
        case .autoColor(let gains): gains == .identity
        case .whiteBalance(let gains): gains == .identity
        case .adjust(let adjustments): adjustments == Adjustments()
        case .levels(let l): l.isIdentity
        case .curves(let c): c.isIdentity
        case .colorRanges(let r): r.isIdentity
        case .orient(let orientation): orientation == .identity
        case .straighten(let degrees): degrees == 0
        case .crop(let rect): rect == .full
        case .resize: false
        }
    }
}

// MARK: - Codable

// Encoded as {"op": "<kind>", "value": {...}} so sidecar files stay readable and
// new operation kinds can be added without breaking old files.
extension EditOperation: Codable {
    private enum CodingKeys: String, CodingKey { case op, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .op)
        switch kind {
        case .magicFix: self = .magicFix(try c.decode(FilterChain.self, forKey: .value))
        case .autoContrast: self = .autoContrast(try c.decode(Levels.self, forKey: .value))
        case .autoColor: self = .autoColor(try c.decode(ChannelGains.self, forKey: .value))
        case .whiteBalance: self = .whiteBalance(try c.decode(ChannelGains.self, forKey: .value))
        case .adjust: self = .adjust(try c.decode(Adjustments.self, forKey: .value))
        case .levels: self = .levels(try c.decode(ToneLevels.self, forKey: .value))
        case .curves: self = .curves(try c.decode(Curves.self, forKey: .value))
        case .colorRanges: self = .colorRanges(try c.decode(ColorRanges.self, forKey: .value))
        case .orient: self = .orient(try c.decode(Orientation.self, forKey: .value))
        case .straighten: self = .straighten(degrees: try c.decode(Double.self, forKey: .value))
        case .crop: self = .crop(try c.decode(CropRect.self, forKey: .value))
        case .resize: self = .resize(try c.decode(ResizeSpec.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .op)
        switch self {
        case .magicFix(let v): try c.encode(v, forKey: .value)
        case .autoContrast(let v): try c.encode(v, forKey: .value)
        case .autoColor(let v): try c.encode(v, forKey: .value)
        case .whiteBalance(let v): try c.encode(v, forKey: .value)
        case .adjust(let v): try c.encode(v, forKey: .value)
        case .levels(let v): try c.encode(v, forKey: .value)
        case .curves(let v): try c.encode(v, forKey: .value)
        case .colorRanges(let v): try c.encode(v, forKey: .value)
        case .orient(let v): try c.encode(v, forKey: .value)
        case .straighten(let v): try c.encode(v, forKey: .value)
        case .crop(let v): try c.encode(v, forKey: .value)
        case .resize(let v): try c.encode(v, forKey: .value)
        }
    }
}

// MARK: - Parameter types

/// Light and color slider values. Every value is 0 when untouched.
public struct Adjustments: Codable, Equatable, Sendable {
    /// Exposure in stops, −3…+3.
    public var exposure: Double = 0
    /// −1…+1 for the rest unless noted.
    public var brightness: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    /// Fill light, 0…1: lifts shadows without touching highlights.
    public var fillLight: Double = 0
    /// Warmth: negative is cooler (bluer), positive is warmer (more orange).
    public var temperature: Double = 0
    /// Negative is greener, positive is more magenta.
    public var tint: Double = 0
    public var saturation: Double = 0
    public var vibrance: Double = 0
    /// Detail, 0…1 for sharpness, −1…+1 for the others.
    public var sharpness: Double = 0
    /// Local contrast over large areas ("clarity").
    public var clarity: Double = 0
    /// Local contrast in fine texture.
    public var structure: Double = 0
    /// Vignette: negative darkens the corners, positive lightens them.
    public var vignette: Double = 0
    /// How far the vignette reaches in from the corners, 0…1.
    public var vignetteSize: Double = 0.5
    /// Smooths grainy brightness noise, 0…1.
    public var noiseReduction: Double = 0
    /// Smooths colored speckles, 0…1.
    public var colorNoiseReduction: Double = 0

    public init() {}

    // Decode leniently so a sidecar written by a newer version with extra
    // sliders, or an older one with fewer, still opens.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        exposure = try v(.exposure)
        brightness = try v(.brightness)
        contrast = try v(.contrast)
        highlights = try v(.highlights)
        shadows = try v(.shadows)
        whites = try v(.whites)
        blacks = try v(.blacks)
        fillLight = try v(.fillLight)
        temperature = try v(.temperature)
        tint = try v(.tint)
        saturation = try v(.saturation)
        vibrance = try v(.vibrance)
        sharpness = try v(.sharpness)
        clarity = try v(.clarity)
        structure = try v(.structure)
        vignette = try v(.vignette)
        vignetteSize = try c.decodeIfPresent(Double.self, forKey: .vignetteSize) ?? 0.5
        noiseReduction = try v(.noiseReduction)
        colorNoiseReduction = try v(.colorNoiseReduction)
    }
}

/// Black and white input points for a contrast stretch, in linear 0…1.
public struct Levels: Codable, Equatable, Sendable {
    public var black: Double
    public var white: Double
    public init(black: Double, white: Double) {
        self.black = black
        self.white = white
    }
    public static let identity = Levels(black: 0, white: 1)
}

/// Per-channel multipliers used to neutralize a color cast.
public struct ChannelGains: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
    public static let identity = ChannelGains(red: 1, green: 1, blue: 1)
}

/// A rotation by quarter turns plus an optional mirror. The mirror (left–right flip)
/// is applied first, then the clockwise quarter turns.
public struct Orientation: Codable, Equatable, Sendable {
    /// Clockwise quarter turns, 0…3.
    public var quarterTurns: Int
    public var mirrored: Bool

    public init(quarterTurns: Int = 0, mirrored: Bool = false) {
        self.quarterTurns = ((quarterTurns % 4) + 4) % 4
        self.mirrored = mirrored
    }

    public static let identity = Orientation()

    /// True when width and height are swapped.
    public var swapsDimensions: Bool { quarterTurns % 2 == 1 }

    /// This orientation followed by a clockwise (or counterclockwise) quarter turn.
    public func rotated(clockwise: Bool) -> Orientation {
        Orientation(quarterTurns: quarterTurns + (clockwise ? 1 : -1), mirrored: mirrored)
    }

    /// This orientation followed by a left–right flip of the result.
    /// flipH ∘ R(r) ∘ M^m = R(−r) ∘ M^(m+1)
    public func flippedHorizontally() -> Orientation {
        Orientation(quarterTurns: -quarterTurns, mirrored: !mirrored)
    }

    /// This orientation followed by an upside-down flip of the result.
    /// flipV = R(2) ∘ flipH, so flipV ∘ R(r) ∘ M^m = R(2 − r) ∘ M^(m+1)
    public func flippedVertically() -> Orientation {
        Orientation(quarterTurns: 2 - quarterTurns, mirrored: !mirrored)
    }
}

/// A crop rectangle in normalized coordinates (0…1), origin at the top left.
public struct CropRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    /// Keeps the rectangle inside 0…1 with a minimum size.
    public func clamped(minSize: Double = 0.01) -> CropRect {
        let w = min(max(width, minSize), 1)
        let h = min(max(height, minSize), 1)
        return CropRect(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    /// The same region after the image is turned a quarter turn clockwise.
    public func rotatedClockwise() -> CropRect {
        CropRect(x: 1 - y - height, y: x, width: height, height: width)
    }

    public func rotatedCounterclockwise() -> CropRect {
        CropRect(x: y, y: 1 - x - width, width: height, height: width)
    }

    public func flippedHorizontally() -> CropRect {
        CropRect(x: 1 - x - width, y: y, width: width, height: height)
    }

    public func flippedVertically() -> CropRect {
        CropRect(x: x, y: 1 - y - height, width: width, height: height)
    }
}

/// Output size for export.
public struct ResizeSpec: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Pixels per inch to record in the file, when the size was chosen as a print size.
    public var dpi: Double?

    public init(width: Int, height: Int, dpi: Double? = nil) {
        self.width = width
        self.height = height
        self.dpi = dpi
    }
}

/// A frozen list of Core Image filters with their parameter values.
public struct FilterChain: Codable, Equatable, Sendable {
    public var steps: [FilterStep]
    public init(steps: [FilterStep]) { self.steps = steps }
}

public struct FilterStep: Codable, Equatable, Sendable {
    public var name: String
    public var parameters: [String: FilterValue]
    public init(name: String, parameters: [String: FilterValue]) {
        self.name = name
        self.parameters = parameters
    }
}

public enum FilterValue: Codable, Equatable, Sendable {
    case number(Double)
    case vector([Double])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else {
            self = .vector(try c.decode([Double].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .vector(let v): try c.encode(v)
        }
    }
}
