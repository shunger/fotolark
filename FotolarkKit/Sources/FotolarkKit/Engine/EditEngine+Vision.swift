import CoreImage
import Foundation
import Vision

/// One-click fixes that look at what's in the photo, using Apple's Vision framework.
extension EditEngine {
    // MARK: Auto-straighten

    /// Degrees to straighten by (positive = clockwise) so the horizon is level, or nil if
    /// Vision finds no clear horizon. `image` is the photo after turning, before straightening.
    public func horizonStraightening(for image: CIImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image.normalizedToOrigin(), options: [.ciContext: context])
        guard (try? handler.perform([request])) != nil, let horizon = request.results?.first else { return nil }
        // Vision reports the horizon's tilt with the same sign as our clockwise
        // straighten angle, so leveling it means turning the other way.
        let degrees = -Double(horizon.angle) * 180 / .pi
        guard abs(degrees) >= 0.1, abs(degrees) <= 45 else { return nil }
        return (degrees * 10).rounded() / 10
    }

    // MARK: Auto-crop

    /// A crop that frames the main subject, keeping the photo's shape. `image` is the
    /// photo after turning and straightening; nil when the subject already fills it.
    public func suggestedCrop(for image: CIImage) -> CropRect? {
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(ciImage: image.normalizedToOrigin(), options: [.ciContext: context])
        guard (try? handler.perform([request])) != nil,
              let objects = request.results?.first?.salientObjects, !objects.isEmpty
        else { return nil }
        // Union of the salient areas, flipped to a top-left origin.
        var box = objects[0].boundingBox
        for o in objects.dropFirst() { box = box.union(o.boundingBox) }
        let subject = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        return Self.frame(subject, imageAspect: Double(image.extent.width / image.extent.height))
    }

    /// The smallest crop of the photo's own shape that holds `subject` with some room
    /// around it, kept inside the photo.
    static func frame(_ subject: CGRect, imageAspect: Double) -> CropRect? {
        let pad = 0.12
        var w = Double(subject.width) * (1 + 2 * pad)
        var h = Double(subject.height) * (1 + 2 * pad)
        // Same shape as the photo (in normalized units the photo's shape is 1:1).
        if w > h { h = w } else { w = h }
        w = min(w, 1); h = min(h, 1)
        // Not worth cropping less than 10% off.
        guard w * h < 0.81 else { return nil }
        let cx = Double(subject.midX), cy = Double(subject.midY)
        let x = min(max(cx - w / 2, 0), 1 - w)
        let y = min(max(cy - h / 2, 0), 1 - h)
        return CropRect(x: x, y: y, width: w, height: h)
    }

    // MARK: Red eye

    /// Finds red pupils in faces. `image` is the original photo (spots are stored on it).
    public func detectRedEyes(in image: CIImage) -> [EyeSpot] {
        let img = image.normalizedToOrigin()
        let e = img.extent
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(ciImage: img, options: [.ciContext: context])
        guard (try? handler.perform([request])) != nil, let faces = request.results else { return [] }
        let size = e.size
        var spots: [EyeSpot] = []
        for face in faces {
            guard let landmarks = face.landmarks else { continue }
            let pairs: [(VNFaceLandmarkRegion2D?, VNFaceLandmarkRegion2D?)] = [
                (landmarks.leftPupil, landmarks.leftEye), (landmarks.rightPupil, landmarks.rightEye),
            ]
            for (pupil, eye) in pairs {
                guard let pupil, let pupilPoint = pupil.pointsInImage(imageSize: size).first else { continue }
                // The pupil is about a third of the eye's width.
                let eyeWidth = eye.map { pts -> CGFloat in
                    let xs = pts.pointsInImage(imageSize: size).map(\.x)
                    return (xs.max() ?? 0) - (xs.min() ?? 0)
                } ?? size.width * 0.02
                let radius = max(eyeWidth * 0.22, 2)
                let spot = EyeSpot(x: pupilPoint.x / size.width, y: 1 - pupilPoint.y / size.height,
                                   radius: radius / max(size.width, size.height))
                if isRed(at: spot, in: img) { spots.append(spot) }
            }
        }
        return spots
    }

    /// A spot clicked by hand: centered on the click, sized for a typical eye.
    public func redEyeSpot(at point: CGPoint, in image: CIImage, radius: Double = 0.012) -> EyeSpot {
        EyeSpot(x: point.x, y: point.y, radius: radius)
    }

    /// True if the middle of the spot is clearly red.
    func isRed(at spot: EyeSpot, in image: CIImage) -> Bool {
        let e = image.extent
        let r = spot.radius * max(e.width, e.height) * 0.6
        let rect = CGRect(x: e.minX + spot.x * e.width - r, y: e.maxY - spot.y * e.height - r, width: 2 * r, height: 2 * r)
            .intersection(e)
        guard !rect.isNull, rect.width >= 1 else { return false }
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes {
            context.render(avg, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return px[0] > 0.25 && px[0] > 1.6 * max(px[1], px[2])
    }
}
