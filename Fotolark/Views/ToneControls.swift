import FotolarkKit
import SwiftUI

/// Channel being edited in the curve editor.
enum CurveChannel: String, CaseIterable, Identifiable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .rgb: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        }
    }

    var keyPath: WritableKeyPath<Curves, ToneCurve> {
        switch self {
        case .rgb: \.rgb
        case .red: \.red
        case .green: \.green
        case .blue: \.blue
        }
    }
}

/// Tone curve editor: drag points, click the curve to add one, double-click a point
/// (or drag it off the side) to remove it.
struct CurvesEditor: View {
    @Bindable var editor: PhotoEditor
    @State private var channel = CurveChannel.rgb
    @State private var dragIndex: Int?

    private var curve: ToneCurve { editor.recipe.curves[keyPath: channel.keyPath] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Channel", selection: $channel) {
                ForEach(CurveChannel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    Canvas { context, size in
                        var grid = Path()
                        for i in 1..<4 {
                            let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
                            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
                        var diag = Path()
                        diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
                        context.stroke(diag, with: .color(.secondary.opacity(0.3)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        var line = Path()
                        for i in 0...100 {
                            let x = Double(i) / 100
                            let p = CGPoint(x: size.width * x, y: size.height * (1 - curve.value(at: x)))
                            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                        }
                        context.stroke(line, with: .color(channel.color), lineWidth: 1.5)
                    }
                    ForEach(Array(curve.points.enumerated()), id: \.offset) { i, p in
                        Circle()
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().strokeBorder(channel.color, lineWidth: 1.5))
                            .frame(width: 11, height: 11)
                            .position(x: size.width * p.x, y: size.height * (1 - p.y))
                            .onTapGesture(count: 2) { removePoint(i) }
                            .accessibilityLabel("Curve point \(i + 1)")
                            .accessibilityValue("input \(Int(p.x * 100)), output \(Int(p.y * 100))")
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag(to: $0.location, start: $0.startLocation, in: size) }
                        .onEnded { _ in
                            dragIndex = nil
                            editor.commitPending()
                        }
                )
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))

            HStack {
                Button("Reset \(channel == .rgb ? "Curve" : channel.rawValue)") { setCurve(.straight) }
                    .disabled(curve.isStraight)
                Spacer()
                Button("Reset All") { editor.apply(editor.recipe.removing(.curves), label: "Reset curves") }
                    .disabled(editor.recipe.curves.isIdentity)
            }
            .controlSize(.small)
        }
    }

    private func point(_ location: CGPoint, in size: CGSize) -> CurvePoint {
        CurvePoint(min(max(location.x / size.width, 0), 1), min(max(1 - location.y / size.height, 0), 1))
    }

    private func drag(to location: CGPoint, start: CGPoint, in size: CGSize) {
        var points = curve.points.sorted { $0.x < $1.x }
        if dragIndex == nil {
            // Grab the nearest point, or add one on the curve where the drag began.
            let s = point(start, in: size)
            if let nearest = points.indices.min(by: { hypot(points[$0].x - s.x, points[$0].y - s.y) < hypot(points[$1].x - s.x, points[$1].y - s.y) }),
               hypot(points[nearest].x - s.x, points[nearest].y - s.y) < 0.06 {
                dragIndex = nearest
            } else {
                points.append(CurvePoint(s.x, curve.value(at: s.x)))
                points.sort { $0.x < $1.x }
                dragIndex = points.firstIndex { $0.x == s.x }
            }
        }
        guard let i = dragIndex, points.indices.contains(i) else { return }
        var p = point(location, in: size)
        // Points keep their order; the end points stay at the edges.
        let lo = i == 0 ? 0 : points[i - 1].x + 0.01
        let hi = i == points.count - 1 ? 1 : points[i + 1].x - 0.01
        if i == 0 { p.x = min(p.x, hi) } else if i == points.count - 1 { p.x = max(p.x, lo) } else { p.x = min(max(p.x, lo), hi) }
        points[i] = p
        setCurve(ToneCurve(points: points), live: true)
    }

    private func removePoint(_ i: Int) {
        var points = curve.points.sorted { $0.x < $1.x }
        guard i > 0, i < points.count - 1 else { return }
        points.remove(at: i)
        setCurve(ToneCurve(points: points))
    }

    private func setCurve(_ c: ToneCurve, live: Bool = false) {
        var all = editor.recipe.curves
        all[keyPath: channel.keyPath] = c
        let r = editor.recipe.setting(.curves(all))
        if live { editor.setLive(r, label: "Curves") } else { editor.apply(r, label: "Curves") }
    }
}

/// Input black, midtones and white; output black and white.
struct LevelsControls: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Input black", \.inputBlack, 0...0.9, reset: 0)
            row("Midtones", \.gamma, 0.2...3, reset: 1, text: { String(format: "%.2f", $0) })
            row("Input white", \.inputWhite, 0.1...1, reset: 1)
            row("Output black", \.outputBlack, 0...0.9, reset: 0)
            row("Output white", \.outputWhite, 0.1...1, reset: 1)
        }
    }

    private func row(_ title: String, _ key: WritableKeyPath<ToneLevels, Double>, _ range: ClosedRange<Double>,
                     reset: Double, text: ((Double) -> String)? = nil) -> some View {
        let value = editor.recipe.toneLevels[keyPath: key]
        let set = { (v: Double) in
            var l = editor.recipe.toneLevels
            l[keyPath: key] = v
            editor.setLive(editor.recipe.setting(.levels(l)), label: "Levels")
        }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).onTapGesture(count: 2) { set(reset); editor.commitPending() }
                Spacer()
                Text(text?(value) ?? "\(Int((value * 255).rounded()))").monospacedDigit()
                    .foregroundStyle(value == reset ? .secondary : .primary)
            }
            .font(.callout)
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range) { if !$0 { editor.commitPending() } }
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityAction(named: "Reset") { set(reset); editor.commitPending() }
        }
    }
}

/// Hue, saturation and lightness for each color range.
struct ColorRangeControls: View {
    @Bindable var editor: PhotoEditor
    @State private var aspect = 1

    private static let swatches: [Color] = [
        .red, .orange, .yellow, .green, Color(red: 0.2, green: 0.8, blue: 0.85), .blue, .purple,
        Color(red: 0.9, green: 0.2, blue: 0.7),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Adjust", selection: $aspect) {
                Text("Hue").tag(0)
                Text("Saturation").tag(1)
                Text("Lightness").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ForEach(ColorRanges.Band.allCases) { band in
                let value = current(band)
                HStack(spacing: 8) {
                    Circle().fill(Self.swatches[band.rawValue]).frame(width: 10, height: 10).accessibilityHidden(true)
                    Text(band.title).frame(width: 60, alignment: .leading)
                        .onTapGesture(count: 2) { set(band, 0); editor.commitPending() }
                    Slider(value: Binding(get: { value }, set: { set(band, $0) }), in: -1...1) {
                        if !$0 { editor.commitPending() }
                    }
                    .controlSize(.small)
                    .accessibilityLabel("\(band.title) \(["hue", "saturation", "lightness"][aspect])")
                    Text(value == 0 ? "0" : String(format: "%+.0f", value * 100))
                        .monospacedDigit().frame(width: 34, alignment: .trailing)
                        .foregroundStyle(value == 0 ? .secondary : .primary)
                }
                .font(.callout)
            }
        }
    }

    private func current(_ band: ColorRanges.Band) -> Double {
        let a = editor.recipe.colorRanges[band]
        return [a.hue, a.saturation, a.lightness][aspect]
    }

    private func set(_ band: ColorRanges.Band, _ v: Double) {
        var r = editor.recipe.colorRanges
        switch aspect {
        case 0: r[band].hue = v
        case 1: r[band].saturation = v
        default: r[band].lightness = v
        }
        editor.setLive(editor.recipe.setting(.colorRanges(r)), label: "Color ranges")
    }
}
