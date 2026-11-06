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

public struct ExportOptions: Codable, Equatable, Sendable {
    public var format: ExportFormat
    /// 0…1, for JPEG and HEIC.
    public var quality: Double
    public var colorSpace: ExportColorSpace

    public init(format: ExportFormat = .jpeg, quality: Double = 0.9, colorSpace: ExportColorSpace = .sRGB) {
        self.format = format
        self.quality = quality
        self.colorSpace = colorSpace
    }
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
        let image = RecipeRenderer.apply(recipe, to: try ImageLoader.loadFull(source))
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
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyExifAuxDictionary] {
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
