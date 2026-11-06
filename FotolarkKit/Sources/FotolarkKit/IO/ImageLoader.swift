import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum FotolarkError: LocalizedError, Equatable {
    case cannotRead(String)
    case cannotEncode(String)
    case cannotOverwrite(String)

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let name): "“\(name)” couldn’t be opened. It may be damaged or in a format Fotolark can’t read."
        case .cannotEncode(let format): "The photo couldn’t be saved as \(format)."
        case .cannotOverwrite(let reason): reason
        }
    }
}

/// Facts about a photo file, read without decoding the pixels.
public struct PhotoInfo: Equatable, Sendable {
    public let url: URL
    /// Size as the photo is meant to be seen (camera orientation already applied).
    public let pixelSize: PixelSize
    public let typeIdentifier: String?
    /// True when the file is tagged with a wide-gamut color space such as Display P3.
    public let isWideGamut: Bool
}

public enum ImageLoader {
    /// Formats Fotolark opens, including camera RAW files.
    public static let readableTypes: [UTType] = [
        .jpeg, .png, .heic, .heif, .tiff, .gif, .webP, .bmp, .rawImage,
    ]

    public static func isRAW(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) ?? false
    }

    public static func canOpen(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return readableTypes.contains { type.conforms(to: $0) }
    }

    public static func info(for url: URL) throws -> PhotoInfo {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw FotolarkError.cannotRead(url.lastPathComponent) }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // EXIF orientations 5–8 are turned a quarter, so width and height swap.
        var size = (5...8).contains(orientation) ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
        // RAW files are developed by Core Image, whose output (after the camera's default
        // crop and orientation) is what Fotolark edits; use its size so all geometry agrees.
        if isRAW(url), let extent = CIRAWFilter(imageURL: url)?.outputImage?.extent, !extent.isInfinite {
            size = PixelSize(extent.size)
        }
        // Creating the CGImage reads the header only; pixels are decoded lazily.
        let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        let wide = cg?.colorSpace?.isWideGamutRGB ?? false
        return PhotoInfo(url: url, pixelSize: size,
                         typeIdentifier: CGImageSourceGetType(src) as String?,
                         isWideGamut: wide)
    }

    /// The whole photo at full resolution, upright.
    public static func loadFull(_ url: URL) throws -> CIImage {
        if isRAW(url) {
            guard let raw = CIRAWFilter(imageURL: url), let image = raw.outputImage else {
                throw FotolarkError.cannotRead(url.lastPathComponent)
            }
            return image.normalizedToOrigin()
        }
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw FotolarkError.cannotRead(url.lastPathComponent)
        }
        return image.normalizedToOrigin()
    }

    /// A smaller, upright copy for fast on-screen editing. ImageIO decodes straight to
    /// the smaller size, which is much faster than decoding the whole photo.
    public static func loadPreview(_ url: URL, maxPixelSize: Int) throws -> CIImage {
        if isRAW(url) { return try loadRAWPreview(url, maxPixelSize: maxPixelSize) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FotolarkError.cannotRead(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw FotolarkError.cannotRead(url.lastPathComponent)
        }
        return CIImage(cgImage: cg)
    }
}

extension ImageLoader {
    private static let rawContext = CIContext(options: [.cacheIntermediates: false])

    /// RAW previews are developed with the same RAW processing as the export, at a smaller
    /// scale, then kept as a bitmap so slider changes don't re-develop the RAW each time.
    /// (A camera's embedded JPEG preview would look different from the export.)
    static func loadRAWPreview(_ url: URL, maxPixelSize: Int) throws -> CIImage {
        guard let raw = CIRAWFilter(imageURL: url) else { throw FotolarkError.cannotRead(url.lastPathComponent) }
        let native = raw.nativeSize
        let longest = max(native.width, native.height)
        if longest > CGFloat(maxPixelSize) {
            raw.scaleFactor = Float(CGFloat(maxPixelSize) / longest)
            raw.isDraftModeEnabled = true
        }
        guard let image = raw.outputImage?.normalizedToOrigin(),
              let cg = rawContext.createCGImage(image, from: image.extent, format: .RGBAh,
                                                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        else { throw FotolarkError.cannotRead(url.lastPathComponent) }
        return CIImage(cgImage: cg)
    }
}
