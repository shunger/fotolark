import AppKit
import FotolarkKit
import SwiftUI

// MARK: - Canvas overlays

/// Paint with the selected brush, or place the selected gradient.
struct LocalOverlay: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        if editor.selectedLocal?.kind == .gradient {
            GradientOverlay(editor: editor)
        } else {
            BrushOverlay(editor: editor)
        }
    }
}

private struct BrushOverlay: View {
    @Bindable var editor: PhotoEditor
    @State private var hover: CGPoint?
    @State private var stroke: [CGPoint] = []
    @State private var erasing = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let longest = max(size.width, size.height)
            ZStack {
                Color.clear.contentShape(Rectangle())
                Path { p in
                    guard let first = stroke.first else { return }
                    p.move(to: first)
                    for pt in stroke.dropFirst() { p.addLine(to: pt) }
                }
                .stroke((erasing ? Color.red : Color.white).opacity(0.4),
                        style: StrokeStyle(lineWidth: editor.brushSize * 2, lineCap: .round, lineJoin: .round))
                if let hover {
                    Circle()
                        .strokeBorder(editor.localErase || NSEvent.modifierFlags.contains(.option) ? Color.red : Color.white,
                                      lineWidth: 1)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .frame(width: editor.brushSize * 2, height: editor.brushSize * 2)
                        .position(hover)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p; NSCursor.crosshair.set()
                case .ended: hover = nil; NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if stroke.isEmpty { erasing = editor.localErase || NSEvent.modifierFlags.contains(.option) }
                        hover = value.location
                        if stroke.last.map({ hypot($0.x - value.location.x, $0.y - value.location.y) > 2 }) ?? true {
                            stroke.append(value.location)
                        }
                    }
                    .onEnded { value in
                        defer { stroke = [] }
                        let pts = (stroke.isEmpty ? [value.location] : stroke)
                            .map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) }
                        editor.addLocalStroke(displayPoints: pts, radiusFraction: editor.brushSize / longest, erase: erasing)
                    }
            )
        }
        .accessibilityLabel("Paint where the adjustment should apply. Hold Option to erase.")
    }
}

private struct GradientOverlay: View {
    @Bindable var editor: PhotoEditor
    /// Which end is being dragged; nil while drawing a new gradient.
    @State private var dragging: End?

    enum End { case start, end, both }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let ends = handles(in: size)
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let (s, e) = ends {
                    // Full strength beyond the first line, none beyond the second.
                    guideLine(through: s, direction: CGPoint(x: e.x - s.x, y: e.y - s.y), size: size, dashed: false)
                    guideLine(through: e, direction: CGPoint(x: e.x - s.x, y: e.y - s.y), size: size, dashed: true)
                    Path { p in p.move(to: s); p.addLine(to: e) }
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                    handle(at: s, filled: true)
                    handle(at: e, filled: false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let norm = { (p: CGPoint) in CGPoint(x: p.x / size.width, y: p.y / size.height) }
                        let near = { (p: CGPoint) in hypot(v.startLocation.x - p.x, v.startLocation.y - p.y) < 14 }
                        if dragging == nil {
                            if let (s, _) = ends, near(s) {
                                dragging = .start
                            } else if let (_, e) = ends, near(e) {
                                dragging = .end
                            } else {
                                dragging = .both
                            }
                        }
                        switch dragging {
                        case .start:
                            if let (_, e) = ends { editor.setGradient(start: norm(v.location), end: norm(e), live: true) }
                        case .end:
                            if let (s, _) = ends { editor.setGradient(start: norm(s), end: norm(v.location), live: true) }
                        default:
                            editor.setGradient(start: norm(v.startLocation), end: norm(v.location), live: true)
                        }
                    }
                    .onEnded { _ in
                        dragging = nil
                        editor.commitPending()
                    }
            )
        }
        .accessibilityLabel("Drag from where the effect is strongest to where it fades out")
    }

    private func handles(in size: CGSize) -> (CGPoint, CGPoint)? {
        guard let adj = editor.selectedLocal, adj.kind == .gradient else { return nil }
        let s = editor.displayPointUnclamped(adj.start), e = editor.displayPointUnclamped(adj.end)
        return (CGPoint(x: s.x * size.width, y: s.y * size.height), CGPoint(x: e.x * size.width, y: e.y * size.height))
    }

    private func handle(at p: CGPoint, filled: Bool) -> some View {
        Circle()
            .fill(filled ? Color.white : Color.clear)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.6), radius: 1)
            .frame(width: 14, height: 14)
            .position(p)
            .allowsHitTesting(false)
    }

    /// A long line through `p`, square to `direction`.
    private func guideLine(through p: CGPoint, direction d: CGPoint, size: CGSize, dashed: Bool) -> some View {
        let len = max(hypot(d.x, d.y), 0.001)
        let n = CGPoint(x: -d.y / len, y: d.x / len)
        let reach = size.width + size.height
        return Path { path in
            path.move(to: CGPoint(x: p.x - n.x * reach, y: p.y - n.y * reach))
            path.addLine(to: CGPoint(x: p.x + n.x * reach, y: p.y + n.y * reach))
        }
        .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, dash: dashed ? [6, 4] : []))
        .shadow(color: .black.opacity(0.6), radius: 1)
        .allowsHitTesting(false)
    }
}

/// Drag the band to move it; drag the round handle to turn it.
struct TiltShiftOverlay: View {
    @Bindable var editor: PhotoEditor
    @State private var mode: Mode?
    @State private var startCenter: CGPoint?

    enum Mode { case move, turn }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let band = editor.tiltShiftOnScreen(in: size), let t = editor.recipe.tiltShift {
                    let scale = Double(max(size.width, size.height)) / Double(max(editor.shownSize.width, editor.shownSize.height))
                    let srcLongest = Double(max(editor.info.pixelSize.width, editor.info.pixelSize.height))
                    let inner = t.focus * srcLongest * scale
                    let outer = (t.focus + t.feather) * srcLongest * scale
                    line(band, offset: 0, size: size, style: StrokeStyle(lineWidth: 1.5))
                    line(band, offset: inner, size: size, style: StrokeStyle(lineWidth: 1))
                    line(band, offset: -inner, size: size, style: StrokeStyle(lineWidth: 1))
                    line(band, offset: outer, size: size, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    line(band, offset: -outer, size: size, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                    Circle().fill(.white).frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .position(band.center)
                        .allowsHitTesting(false)
                    Circle().strokeBorder(.white, lineWidth: 2).frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .position(turnHandle(band))
                        .allowsHitTesting(false)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        guard let band = editor.tiltShiftOnScreen(in: size) else { return }
                        if mode == nil {
                            let h = turnHandle(band)
                            mode = hypot(v.startLocation.x - h.x, v.startLocation.y - h.y) < 16 ? .turn : .move
                            startCenter = band.center
                        }
                        switch mode {
                        case .turn:
                            let a = atan2(v.location.y - band.center.y, v.location.x - band.center.x)
                            editor.placeTiltShift(center: band.center, angle: a, in: size, live: true)
                        default:
                            let c0 = startCenter ?? band.center
                            let c = CGPoint(x: c0.x + v.translation.width, y: c0.y + v.translation.height)
                            editor.placeTiltShift(center: c, angle: band.angle, in: size, live: true)
                        }
                    }
                    .onEnded { _ in
                        mode = nil
                        startCenter = nil
                        editor.commitPending()
                    }
            )
        }
        .accessibilityLabel("Drag to move the sharp band; drag the round handle to turn it")
    }

    private func turnHandle(_ band: (center: CGPoint, angle: Double)) -> CGPoint {
        CGPoint(x: band.center.x + cos(band.angle) * 90, y: band.center.y + sin(band.angle) * 90)
    }

    private func line(_ band: (center: CGPoint, angle: Double), offset: Double, size: CGSize, style: StrokeStyle) -> some View {
        let d = CGPoint(x: cos(band.angle), y: sin(band.angle))
        let n = CGPoint(x: -d.y, y: d.x)
        let p = CGPoint(x: band.center.x + n.x * offset, y: band.center.y + n.y * offset)
        let reach = size.width + size.height
        return Path { path in
            path.move(to: CGPoint(x: p.x - d.x * reach, y: p.y - d.y * reach))
            path.addLine(to: CGPoint(x: p.x + d.x * reach, y: p.y + d.y * reach))
        }
        .stroke(Color.white.opacity(0.85), style: style)
        .shadow(color: .black.opacity(0.6), radius: 1)
        .allowsHitTesting(false)
    }
}

// MARK: - Panels

/// Brush and gradient adjustments: the list, and the selected one's settings.
struct LocalPanel: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Brush and Gradient").font(.headline)
            HStack {
                Button { editor.addLocal(.brush) } label: { Label("New Brush", systemImage: "paintbrush.pointed") }
                Button { editor.addLocal(.gradient) } label: { Label("New Gradient", systemImage: "square.bottomhalf.filled") }
            }
            .controlSize(.small)

            if !editor.localAdjustments.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(editor.localAdjustments.enumerated()), id: \.element.id) { i, adj in
                        row(adj, number: number(of: adj, at: i))
                    }
                }
            }

            if let adj = editor.selectedLocal {
                Text(adj.kind == .brush
                     ? "Paint over the photo where this should apply. Hold ⌥ (Option) to erase."
                     : "Drag across the photo from where the effect is strongest to where it fades out.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if adj.kind == .brush {
                    Picker("Brush", selection: $editor.localErase) {
                        Text("Paint").tag(false)
                        Text("Erase").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text("Brush size"); Spacer(); Text("\(Int(editor.brushSize))").monospacedDigit() }.font(.callout)
                        Slider(value: $editor.brushSize, in: 4...200).controlSize(.small).accessibilityLabel("Brush size")
                    }
                }
                Divider()
                setting("Exposure", \.exposure, adj)
                setting("Contrast", \.contrast, adj)
                setting("Saturation", \.saturation, adj)
                setting("Warmth", \.warmth, adj)
                setting("Blur", \.blur, adj, range: 0...1)
                Button("Delete \(adj.kind == .brush ? "Brush" : "Gradient")", role: .destructive) { editor.removeLocal(adj.id) }
            } else {
                Text("Add a brush to paint light, color or blur onto part of the photo, or a gradient to darken a bright sky.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Button("Done") { editor.tool = .none }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func number(of adj: LocalAdjustment, at index: Int) -> Int {
        editor.localAdjustments.prefix(index + 1).filter { $0.kind == adj.kind }.count
    }

    private func row(_ adj: LocalAdjustment, number: Int) -> some View {
        let selected = adj.id == editor.selectedLocalID
        return HStack {
            Image(systemName: adj.kind == .brush ? "paintbrush.pointed" : "square.bottomhalf.filled")
            Text("\(adj.kind == .brush ? "Brush" : "Gradient") \(number)")
            Spacer()
            if adj.isEmpty { Text("No effect yet").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture { editor.selectedLocalID = adj.id; editor.localErase = false }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func setting(_ title: String, _ key: WritableKeyPath<LocalAdjustment.Settings, Double>, _ adj: LocalAdjustment,
                         range: ClosedRange<Double> = -1...1) -> some View {
        HStack {
            Text(title).font(.callout).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { adj.settings[keyPath: key] }, set: { v in
                var a = editor.selectedLocal ?? adj
                a.settings[keyPath: key] = v
                editor.updateLocal(a, label: title)
            }), in: range) { if !$0 { editor.commitPending() } }
            .controlSize(.small)
            .accessibilityLabel(title)
            Text("\(Int((adj.settings[keyPath: key] * 100).rounded()))")
                .font(.caption).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .onTapGesture(count: 2) {
            var a = adj
            a.settings[keyPath: key] = 0
            editor.updateLocal(a, live: false, label: title)
        }
    }
}

struct TiltShiftPanel: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tilt-Shift").font(.headline)
            Text("Makes a scene look like a tiny model: sharp along a band, blurred above and below. Drag the band to move it, or the round handle to turn it. Works best on photos taken from high up.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let t = editor.recipe.tiltShift {
                slider("Blur", \.blur, t, range: 0...1)
                slider("Sharp band", \.focus, t, range: 0.01...0.3)
                slider("Fade", \.feather, t, range: 0.02...0.5)
                slider("Vivid", \.vivid, t, range: 0...1)
                Button("Remove Tilt-Shift", role: .destructive) { editor.removeTiltShift() }
            }
            Button("Done") { editor.tool = .none }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<TiltShift, Double>, _ t: TiltShift,
                        range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.callout).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { t[keyPath: key] }, set: { v in
                var n = editor.recipe.tiltShift ?? t
                n[keyPath: key] = v
                editor.setTiltShift(n)
            }), in: range) { if !$0 { editor.commitPending() } }
            .controlSize(.small)
            .accessibilityLabel(title)
        }
    }
}

/// Distortion and color-fringe sliders.
struct LensControls: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        let lens = editor.recipe.lens
        VStack(alignment: .leading, spacing: 8) {
            row("Distortion", value: lens.distortion,
                help: "Right straightens lines that bow outward (wide lenses); left straightens lines that bow inward") { v in
                var l = editor.recipe.lens; l.distortion = v; editor.setLens(l)
            }
            row("Color fringes", value: lens.chromatic,
                help: "Lines up red and blue edges near the corners. Zoom in on a high-contrast edge to judge it") { v in
                var l = editor.recipe.lens; l.chromatic = v; editor.setLens(l)
            }
        }
    }

    private func row(_ title: String, value: Double, help: String, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.callout).frame(width: 90, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: -1...1) { if !$0 { editor.commitPending() } }
                .controlSize(.small)
                .accessibilityLabel(title)
            Text("\(Int((value * 100).rounded()))").font(.caption).monospacedDigit().frame(width: 30, alignment: .trailing)
        }
        .help(help + ". Double-click to reset.")
        .onTapGesture(count: 2) { set(0); editor.commitPending() }
    }
}
