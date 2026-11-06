import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case jpeg, png, heic, tiff

    public var id: String { rawValue }

    public var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        }
    }

    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .tiff: "TIFF"
        }
    }

    public var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }

    /// Whether the quality setting applies.
    public var isLossy: Bool { self == .jpeg || self == .heic }

    /// The export format matching a file type, if Fotolark can write it.
    public init?(typeIdentifier: String?) {
        guard let id = typeIdentifier, let type = UTType(id) else { return nil }
        guard let match = ExportFormat.allCases.first(where: { type.conforms(to: $0.utType) }) else { return nil }
        self = match
    }
}

public enum ExportColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case sRGB, displayP3

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sRGB: "sRGB (best for sharing)"
        case .displayP3: "Display P3 (wide color)"
        }
    }

    var cgColorSpace: CGColorSpace {
        CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)!
    }
}

/// Which details from the original travel with an exported copy.
public enum MetadataPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Date, camera, lens, exposure and location.
    case keepAll
    /// Everything except where the photo was taken.
    case removeLocation
    /// No camera data or location at all.
    case removeAll

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .keepAll: "Keep all photo details"
        case .removeLocation: "Remove location"
        case .removeAll: "Remove location and camera details"
        }
    }
}

public struct ExportOptions: Codable, Equatable, Sendable {
    public var format: ExportFormat
    /// 0…1, for JPEG and HEIC.
    public var quality: Double
    public var colorSpace: ExportColorSpace
    public var metadata: MetadataPolicy
    /// Shrinks the photo so its longest side is at most this many pixels (never enlarges).
    public var maxLongestSide: Int?
    /// Added to every exported copy.
    public var watermark: Watermark?

    public init(format: ExportFormat = .jpeg, quality: Double = 0.9, colorSpace: ExportColorSpace = .sRGB,
                metadata: MetadataPolicy = .keepAll, maxLongestSide: Int? = nil, watermark: Watermark? = nil) {
        self.watermark = watermark
        self.format = format
        self.quality = quality
        self.colorSpace = colorSpace
        self.metadata = metadata
        self.maxLongestSide = maxLongestSide
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(ExportFormat.self, forKey: .format)
        quality = try c.decodeIfPresent(Double.self, forKey: .quality) ?? 0.9
        colorSpace = try c.decodeIfPresent(ExportColorSpace.self, forKey: .colorSpace) ?? .sRGB
        metadata = try c.decodeIfPresent(MetadataPolicy.self, forKey: .metadata) ?? .keepAll
        maxLongestSide = try c.decodeIfPresent(Int.self, forKey: .maxLongestSide)
        watermark = try c.decodeIfPresent(Watermark.self, forKey: .watermark)
    }
}

/// A named set of export settings, e.g. "Email (1024 px)".
public struct ExportPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var options: ExportOptions
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, options: ExportOptions, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.options = options
        self.isBuiltIn = isBuiltIn
    }

    public static func == (a: ExportPreset, b: ExportPreset) -> Bool { a.id == b.id && a.name == b.name && a.options == b.options }
    public func hash(into h: inout Hasher) { h.combine(id) }

    // Fixed ids so a chosen built-in preset is remembered between launches.
    public static let builtIn: [ExportPreset] = [
        ExportPreset(id: UUID(uuidString: "6F0A0000-0000-0000-0000-000000000001")!, name: "Full quality",
                     options: ExportOptions(format: .jpeg, quality: 0.95), isBuiltIn: true),
        ExportPreset(id: UUID(uuidString: "6F0A0000-0000-0000-0000-000000000002")!, name: "Web (2048 px)",
                     options: ExportOptions(format: .jpeg, quality: 0.85, metadata: .removeLocation, maxLongestSide: 2048),
                     isBuiltIn: true),
        ExportPreset(id: UUID(uuidString: "6F0A0000-0000-0000-0000-000000000003")!, name: "Email (1024 px)",
                     options: ExportOptions(format: .jpeg, quality: 0.8, metadata: .removeLocation, maxLongestSide: 1024),
                     isBuiltIn: true),
    ]
}

/// Writes edited photos to new files. Camera data (date, camera, lens, location) is
/// carried over from the original.
public enum ImageExporter {
    /// Formats this device can encode (HEIC needs a hardware or software HEVC encoder).
    public static var availableFormats: [ExportFormat] {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return ExportFormat.allCases.filter { ids.contains($0.utType.identifier) }
    }

    public static func encode(source: URL, recipe: EditRecipe, options: ExportOptions,
                              engine: EditEngine) throws -> Data {
        var image = RecipeRenderer.apply(recipe, to: try ImageLoader.loadFull(source))
        if let limit = options.maxLongestSide {
            let size = PixelSize(image.extent.size)
            let fitted = Geometry.fit(size, longestSide: limit)
            if fitted != size {
                image = RecipeRenderer.apply(.resize(ResizeSpec(width: fitted.width, height: fitted.height)), to: image)
            }
        }
        if let watermark = options.watermark {
            image = RecipeRenderer.applyWatermark(watermark, to: image)
        }
        guard let cg = engine.makeCGImage(image, colorSpace: options.colorSpace.cgColorSpace) else {
            throw FotolarkError.cannotEncode(options.format.displayName)
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, options.format.utType.identifier as CFString, 1, nil) else {
            throw FotolarkError.cannotEncode(options.format.displayName)
        }
        let props = metadata(from: source, size: PixelSize(width: cg.width, height: cg.height),
                             dpi: recipe.resize?.dpi, options: options)
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw FotolarkError.cannotEncode(options.format.displayName)
        }
        return data as Data
    }

    /// File name for an exported copy: the original's name with the new extension.
    public static func fileName(for source: URL, format: ExportFormat, suffix: String = "") -> String {
        source.deletingPathExtension().lastPathComponent + suffix + "." + format.fileExtension
    }

    public static func export(source: URL, recipe: EditRecipe, options: ExportOptions,
                              to destination: URL, engine: EditEngine) throws {
        let data = try encode(source: source, recipe: recipe, options: options, engine: engine)
        // Not atomic: a sandboxed app may only touch the one file the person chose,
        // not a temporary file beside it.
        try data.write(to: destination)
    }

    /// The original's metadata, updated for the new pixels: upright orientation, new size.
    static func metadata(from source: URL, size: PixelSize, dpi: Double?, options: ExportOptions) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        if let src = CGImageSourceCreateWithURL(source as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            var keys = [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyExifAuxDictionary]
            switch options.metadata {
            case .keepAll: break
            case .removeLocation: keys.removeAll { $0 == kCGImagePropertyGPSDictionary }
            case .removeAll: keys = []
            }
            for key in keys {
                if let dict = props[key] { out[key] = dict }
            }
        }
        // The pixels are already upright.
        out[kCGImagePropertyOrientation] = 1
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = size.width
            exif[kCGImagePropertyExifPixelYDimension] = size.height
            out[kCGImagePropertyExifDictionary] = exif
        }
        if let dpi {
            out[kCGImagePropertyDPIWidth] = dpi
            out[kCGImagePropertyDPIHeight] = dpi
        }
        if options.format.isLossy {
            out[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        return out
    }
}
