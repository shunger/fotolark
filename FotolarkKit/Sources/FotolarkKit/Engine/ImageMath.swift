import CoreImage
import Foundation

/// Adds and subtracts images pixel by pixel.
///
/// Core Image keeps colors premultiplied by opacity, so a "color-only" image with zero
/// opacity has no color at all. Instead every term stays fully opaque; the sum then has
/// opacity n (one per term), and a final step divides the opacity back to 1 while
/// scaling the colors by n, which leaves exactly the summed colors.
enum ImageMath {
    /// Σ weightᵢ × imageᵢ (+ bias), fully opaque, over `extent`.
    static func weightedSum(_ terms: [(CIImage, Double)], bias: Double = 0, extent: CGRect) -> CIImage {
        precondition(!terms.isEmpty)
        let scaled = terms.enumerated().map { i, term -> CIImage in
            let (image, w) = term
            let b = i == 0 ? CGFloat(bias) : 0
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: w, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: w, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: w, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
            ]).cropped(to: extent)
        }
        let sum = scaled.dropFirst().reduce(scaled[0]) {
            $1.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: $0])
        }
        let n = CGFloat(terms.count)
        guard n > 1 else { return sum.cropped(to: extent) }
        return sum.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: n, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: n, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: n, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 / n),
        ]).cropped(to: extent)
    }

    /// Gray image whose every channel is the brightness of `image`.
    static func luminance(_ image: CIImage) -> CIImage {
        let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": w, "inputGVector": w, "inputBVector": w])
    }
}
