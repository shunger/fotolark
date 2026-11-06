import Foundation
import ImageIO

/// Camera and file details shown in the Info panel.
public struct PhotoMetadata: Equatable, Sendable {
    public var pixelSize: PixelSize?
    public var dateTaken: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    /// Seconds.
    public var exposureTime: Double?
    public var fNumber: Double?
    public var iso: Int?
    /// Millimeters.
    public var focalLength: Double?
    public var latitude: Double?
    public var longitude: Double?
    /// Meters above sea level.
    public var altitude: Double?
    public var typeIdentifier: String?

    public init() {}

    /// Reads the metadata without decoding the pixels.
    public static func read(_ url: URL) -> PhotoMetadata {
        var m = PhotoMetadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return m }
        m.typeIdentifier = CGImageSourceGetType(src) as String?
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            let o = props[kCGImagePropertyOrientation] as? Int ?? 1
            m.pixelSize = (5...8).contains(o) ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        let dateText = exif[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime] as? String
        m.dateTaken = dateText.flatMap { parseExifDate($0, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String) }

        m.cameraMake = clean(tiff[kCGImagePropertyTIFFMake] as? String)
        m.cameraModel = clean(tiff[kCGImagePropertyTIFFModel] as? String)
        m.lens = clean(exif[kCGImagePropertyExifLensModel] as? String ?? aux[kCGImagePropertyExifAuxLensModel] as? String)
        m.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
        m.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
        m.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        m.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double

        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            m.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            m.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
        if let alt = gps[kCGImagePropertyGPSAltitude] as? Double {
            m.altitude = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1 ? -alt : alt
        }
        return m
    }

    /// Just the capture date, for sorting.
    public static func dateTaken(_ url: URL) -> Date? {
        read(url).dateTaken
    }

    // MARK: Display

    /// e.g. "Apple iPhone 15 Pro" (the make is left out when the model already says it).
    public var cameraName: String? {
        switch (cameraMake, cameraModel) {
        case let (make?, model?):
            model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "")
                ? model : "\(make) \(model)"
        case let (make?, nil): make
        case let (nil, model?): model
        default: nil
        }
    }

    /// e.g. "1/250 s · f/2.8 · ISO 100 · 50 mm"
    public var exposureSummary: String? {
        var parts: [String] = []
        if let t = exposureTime, t > 0 {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let f = fNumber { parts.append(String(format: "f/%.1f", f).replacingOccurrences(of: ".0", with: "")) }
        if let iso { parts.append("ISO \(iso)") }
        if let fl = focalLength { parts.append("\(Int(fl.rounded())) mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. "47.6062° N, 122.3321° W"
    public var coordinatesText: String? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return String(format: "%.4f° %@, %.4f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
    }

    // MARK: Parsing

    static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !t.isEmpty else { return nil }
        return t
    }

    /// EXIF dates look like "2026:07:04 10:30:00". They carry no time zone unless the
    /// camera also wrote an offset; without one the date is read as local time.
    static func parseExifDate(_ text: String, offset: String?) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset, offset.count == 6 {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let d = f.date(from: text + offset) { return d }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: text)
    }
}
