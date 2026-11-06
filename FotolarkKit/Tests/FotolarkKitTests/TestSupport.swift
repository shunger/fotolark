import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import FotolarkKit

/// RGBA8 pixel grid, row 0 at the top.
struct Grid: Equatable, CustomStringConvertible {
    var width: Int
    var height: Int
    var pixels: [[UInt8]]  // each [r, g, b, a]

    subscript(x: Int, y: Int) -> [UInt8] {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// A grid where every pixel has a unique color, so any transform is detectable.
    static func numbered(width: Int, height: Int) -> Grid {
        var g = Grid(width: width, height: height, pixels: [])
        for y in 0..<height {
            for x in 0..<width {
                g.pixels.append([UInt8(40 + x * 40), UInt8(40 + y * 40), 128, 255])
            }
        }
        return g
    }

    func rotatedClockwise() -> Grid {
        var out = Grid(width: height, height: width, pixels: Array(repeating: [0, 0, 0, 0], count: pixels.count))
        for y in 0..<height {
            for x in 0..<width {
                out[height - 1 - y, x] = self[x, y]
            }
        }
        return out
    }

    func rotatedCounterclockwise() -> Grid {
        rotatedClockwise().rotatedClockwise().rotatedClockwise()
    }

    func flippedHorizontally() -> Grid {
        var out = self
        for y in 0..<height { for x in 0..<width { out[width - 1 - x, y] = self[x, y] } }
        return out
    }

    func flippedVertically() -> Grid {
        var out = self
        for y in 0..<height { for x in 0..<width { out[x, height - 1 - y] = self[x, y] } }
        return out
    }

    func cropped(x: Int, y: Int, width w: Int, height h: Int) -> Grid {
        var out = Grid(width: w, height: h, pixels: [])
        for yy in y..<(y + h) { for xx in x..<(x + w) { out.pixels.append(self[xx, yy]) } }
        return out
    }

    var description: String { "\(width)x\(height)" }

    var cgImage: CGImage {
        let bytes = pixels.flatMap { $0 }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    var ciImage: CIImage { CIImage(cgImage: cgImage) }
}

let testEngine = EditEngine()

/// Renders to sRGB RGBA8 and reads the pixels back.
func readGrid(_ image: CIImage) -> Grid {
    let cg = testEngine.makeCGImage(image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
    return readGrid(cg)
}

func readGrid(_ cg: CGImage) -> Grid {
    let w = cg.width, h = cg.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var g = Grid(width: w, height: h, pixels: [])
    for i in stride(from: 0, to: bytes.count, by: 4) { g.pixels.append(Array(bytes[i..<(i + 4)])) }
    return g
}

/// A solid-color image.
func solid(r: Double, g: Double, b: Double, width: Int = 64, height: Int = 48) -> CIImage {
    CIImage(color: CIColor(red: r, green: g, blue: b, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
        .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
}

func averageColor(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
    let grid = readGrid(image)
    var r = 0.0, g = 0.0, b = 0.0
    for p in grid.pixels { r += Double(p[0]); g += Double(p[1]); b += Double(p[2]) }
    let n = Double(grid.pixels.count)
    return (r / n, g / n, b / n)
}

/// A fresh temporary folder for one test.
func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FotolarkKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes `grid` as a file, optionally with an EXIF orientation and capture date.
func writePhoto(_ grid: Grid, to url: URL, type: UTType = .jpeg, orientation: Int? = nil,
                dateTaken: String? = nil) throws {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
    if let orientation { props[kCGImagePropertyOrientation] = orientation }
    if let dateTaken { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dateTaken] }
    CGImageDestinationAddImage(dest, grid.cgImage, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw FotolarkError.cannotEncode(type.identifier) }
}
