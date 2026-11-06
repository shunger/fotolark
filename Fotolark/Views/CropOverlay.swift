import FotolarkKit
import SwiftUI

/// Crop rectangle with drag handles, a rule-of-thirds grid and the area outside dimmed.
/// Works in normalized coordinates (0…1, origin top left) of the uncropped photo.
struct CropOverlay: View {
    @Binding var rect: CropRect
    /// Required width ÷ height in normalized units, or nil for any shape.
    let aspect: Double?

    @State private var dragStart: CropRect?

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
        var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

        /// Position on the unit square.
        var anchor: CGPoint {
            CGPoint(x: movesLeft ? 0 : movesRight ? 1 : 0.5, y: movesTop ? 0 : movesBottom ? 1 : 0.5)
        }

        var label: String {
            switch self {
            case .topLeft: "top left corner"
            case .top: "top edge"
            case .topRight: "top right corner"
            case .right: "right edge"
            case .bottomRight: "bottom right corner"
            case .bottom: "bottom edge"
            case .bottomLeft: "bottom left corner"
            case .left: "left edge"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let frame = CGRect(x: rect.x * size.width, y: rect.y * size.height,
                               width: rect.width * size.width, height: rect.height * size.height)
            ZStack(alignment: .topLeading) {
                // Dim everything outside the crop.
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: size))
                    p.addRect(frame)
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                thirds(in: frame)

                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .frame(width: frame.width, height: frame.height)
                    .contentShape(Rectangle())
                    .offset(x: frame.minX, y: frame.minY)
                    .gesture(moveGesture(size: size))
                    .accessibilityLabel("Crop area")

                ForEach(Handle.allCases, id: \.self) { handle in
                    handleView(handle)
                        .position(x: frame.minX + frame.width * handle.anchor.x,
                                  y: frame.minY + frame.height * handle.anchor.y)
                        .gesture(resizeGesture(handle, size: size))
                        .accessibilityLabel("Crop \(handle.label)")
                }
            }
        }
    }

    private func thirds(in frame: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = frame.minX + frame.width * CGFloat(i) / 3
                let y = frame.minY + frame.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: frame.minY)); p.addLine(to: CGPoint(x: x, y: frame.maxY))
                p.move(to: CGPoint(x: frame.minX, y: y)); p.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.6), lineWidth: 0.75)
        .allowsHitTesting(false)
    }

    private func handleView(_ handle: Handle) -> some View {
        let long: CGFloat = handle.isCorner ? 18 : 22
        let isVerticalEdge = handle == .left || handle == .right
        return ZStack {
            // Generous invisible hit area.
            Color.clear.frame(width: 28, height: 28).contentShape(Rectangle())
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.5), radius: 1)
                .frame(width: handle.isCorner ? long : (isVerticalEdge ? 5 : long),
                       height: handle.isCorner ? long : (isVerticalEdge ? long : 5))
        }
    }

    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? rect
                if dragStart == nil { dragStart = rect }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                rect = CropRect(x: min(max(start.x + dx, 0), 1 - start.width),
                                y: min(max(start.y + dy, 0), 1 - start.height),
                                width: start.width, height: start.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: Handle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? rect
                if dragStart == nil { dragStart = rect }
                rect = Self.resized(start, handle: handle,
                                    dx: value.translation.width / size.width,
                                    dy: value.translation.height / size.height,
                                    aspect: aspect)
            }
            .onEnded { _ in dragStart = nil }
    }

    private static let minSize = 0.03

    private static func resized(_ s: CropRect, handle: Handle, dx: Double, dy: Double, aspect: Double?) -> CropRect {
        var minX = s.x, maxX = s.x + s.width, minY = s.y, maxY = s.y + s.height
        if handle.movesLeft { minX = min(max(minX + dx, 0), maxX - minSize) }
        if handle.movesRight { maxX = max(min(maxX + dx, 1), minX + minSize) }
        if handle.movesTop { minY = min(max(minY + dy, 0), maxY - minSize) }
        if handle.movesBottom { maxY = max(min(maxY + dy, 1), minY + minSize) }
        guard let a = aspect else {
            return CropRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }

        var w = maxX - minX, h = maxY - minY
        if handle.isCorner {
            // Follow whichever direction the pointer moved more.
            if abs(dx) >= abs(dy) * a { h = w / a } else { w = h * a }
            // Room available from the fixed corner.
            let roomW = handle.movesLeft ? s.x + s.width : 1 - s.x
            let roomH = handle.movesTop ? s.y + s.height : 1 - s.y
            if w > roomW { w = roomW; h = w / a }
            if h > roomH { h = roomH; w = h * a }
            let x = handle.movesLeft ? s.x + s.width - w : s.x
            let y = handle.movesTop ? s.y + s.height - h : s.y
            return CropRect(x: x, y: y, width: w, height: h)
        }

        // Edge: the other dimension follows, centered on the start position.
        let center = CGPoint(x: s.x + s.width / 2, y: s.y + s.height / 2)
        if handle.movesLeft || handle.movesRight {
            h = w / a
            let roomH = 2 * min(center.y, 1 - center.y)
            if h > roomH { h = roomH; w = h * a }
            let x = handle.movesLeft ? s.x + s.width - w : s.x
            return CropRect(x: x, y: center.y - h / 2, width: w, height: h)
        } else {
            w = h * a
            let roomW = 2 * min(center.x, 1 - center.x)
            if w > roomW { w = roomW; h = w / a }
            let y = handle.movesTop ? s.y + s.height - h : s.y
            return CropRect(x: center.x - w / 2, y: y, width: w, height: h)
        }
    }
}
