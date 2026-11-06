import AppKit
import FotolarkKit
import SwiftUI

/// Border style, width, color and corner rounding.
struct BorderControls: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        let border = editor.recipe.border
        VStack(alignment: .leading, spacing: 8) {
            Picker("Style", selection: Binding(get: { border?.style }, set: { style in
                guard let style else { editor.setBorder(nil, live: false); return }
                var b = border ?? Border()
                b.style = style
                if style == .polaroid && border?.style != .polaroid { b.color = RGBAColor(red: 0.98, green: 0.97, blue: 0.94) }
                editor.setBorder(b, live: false)
            })) {
                Text("None").tag(Border.Style?.none)
                ForEach(Border.Style.allCases) { Text($0.title).tag(Border.Style?.some($0)) }
            }
            if let b = border {
                row("Width", value: b.width, range: 0...0.15) { var n = b; n.width = $0; editor.setBorder(n) }
                if b.style == .rounded {
                    row("Corners", value: b.cornerRadius, range: 0...0.3) { var n = b; n.cornerRadius = $0; editor.setBorder(n) }
                }
                ColorPicker("Color", selection: Binding(get: {
                    Color(.sRGB, red: b.color.red, green: b.color.green, blue: b.color.blue)
                }, set: { color in
                    guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                    var n = b
                    n.color = RGBAColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
                    editor.setBorder(n, live: false)
                }), supportsOpacity: false)
                Text("The border is added around the photo, so it gets a little bigger.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.callout).frame(width: 60, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range) { if !$0 { editor.commitPending() } }
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

/// Drag to draw a shape; click a shape to select it, drag it to move it.
struct MarkupOverlay: View {
    @Bindable var editor: PhotoEditor
    @State private var drawingID: UUID?
    @State private var moving: (id: UUID, start: CurvePoint, end: CurvePoint)?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.clear.contentShape(Rectangle())
                if let s = editor.selectedShape {
                    let box = frame(of: s, in: size)
                    Rectangle()
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let start = CGPoint(x: v.startLocation.x / size.width, y: v.startLocation.y / size.height)
                        let now = CGPoint(x: v.location.x / size.width, y: v.location.y / size.height)
                        if drawingID == nil && moving == nil {
                            if let hit = hitTest(v.startLocation, in: size) {
                                editor.selectedShapeID = hit.id
                                moving = (hit.id, hit.start, hit.end)
                            } else if hypot(v.translation.width, v.translation.height) > 3 {
                                drawingID = editor.addShape(from: start, to: now)
                            }
                            return
                        }
                        if let m = moving, var s = editor.shapes.first(where: { $0.id == m.id }) {
                            let dx = v.translation.width / size.width, dy = v.translation.height / size.height
                            s.start = CurvePoint(m.start.x + dx, m.start.y + dy)
                            s.end = CurvePoint(m.end.x + dx, m.end.y + dy)
                            editor.updateShape(s)
                        } else if let id = drawingID, var s = editor.shapes.first(where: { $0.id == id }) {
                            s.end = CurvePoint(now.x, now.y)
                            editor.updateShape(s, label: "Add \(s.kind.title.lowercased())")
                        }
                    }
                    .onEnded { v in
                        if drawingID == nil && moving == nil {
                            // A click on empty space clears the selection.
                            editor.selectedShapeID = hitTest(v.location, in: size)?.id
                        }
                        drawingID = nil
                        moving = nil
                        editor.commitPending()
                    }
            )
        }
        .accessibilityLabel("Drag to draw a shape. Click a shape to select it.")
    }

    private func frame(of s: MarkupShape, in size: CGSize) -> CGRect {
        let a = CGPoint(x: s.start.x * size.width, y: s.start.y * size.height)
        let b = CGPoint(x: s.end.x * size.width, y: s.end.y * size.height)
        let pad = max(6, s.lineWidth * max(size.width, size.height) * 2)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .insetBy(dx: -pad, dy: -pad)
    }

    /// The topmost shape under `p`: near the line for lines and arrows, inside the box otherwise.
    private func hitTest(_ p: CGPoint, in size: CGSize) -> MarkupShape? {
        editor.shapes.last { s in
            switch s.kind {
            case .line, .arrow:
                let a = CGPoint(x: s.start.x * size.width, y: s.start.y * size.height)
                let b = CGPoint(x: s.end.x * size.width, y: s.end.y * size.height)
                let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let len2 = max(d.x * d.x + d.y * d.y, 0.001)
                let t = min(max(((p.x - a.x) * d.x + (p.y - a.y) * d.y) / len2, 0), 1)
                let q = CGPoint(x: a.x + d.x * t, y: a.y + d.y * t)
                return hypot(p.x - q.x, p.y - q.y) < 8
            default:
                return frame(of: s, in: size).contains(p)
            }
        }
    }
}

struct MarkupPanel: View {
    @Bindable var editor: PhotoEditor

    private static let swatches: [RGBAColor] = [
        RGBAColor(red: 0.95, green: 0.15, blue: 0.1), RGBAColor(red: 1, green: 0.8, blue: 0),
        RGBAColor(red: 0.2, green: 0.75, blue: 0.3), RGBAColor(red: 0.1, green: 0.45, blue: 1), .white, .black,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shapes and Arrows").font(.headline)
            Text("Drag on the photo to draw. Click a shape to select it; drag it to move it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Shape", selection: $editor.markupKind) {
                Image(systemName: "arrow.up.right").help("Arrow").tag(MarkupShape.Kind.arrow)
                Image(systemName: "line.diagonal").help("Line").tag(MarkupShape.Kind.line)
                Image(systemName: "rectangle").help("Box").tag(MarkupShape.Kind.rectangle)
                Image(systemName: "circle").help("Circle").tag(MarkupShape.Kind.ellipse)
                Image(systemName: "highlighter").help("Highlight").tag(MarkupShape.Kind.highlight)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                ForEach(Self.swatches, id: \.self) { c in
                    Button { editor.setMarkupStyle(color: c) } label: {
                        Circle()
                            .fill(Color(.sRGB, red: c.red, green: c.green, blue: c.blue))
                            .overlay(Circle().strokeBorder(editor.markupColor == c ? Color.accentColor : Color.secondary.opacity(0.4),
                                                           lineWidth: editor.markupColor == c ? 2.5 : 1))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Color")
                }
            }
            HStack {
                Text("Thickness").font(.callout)
                Slider(value: Binding(get: { editor.markupWidth }, set: { editor.setMarkupStyle(width: $0) }), in: 0.002...0.02) {
                    if !$0 { editor.commitPending() }
                }
                .controlSize(.small)
                .accessibilityLabel("Thickness")
            }
            Button("Delete Shape", role: .destructive) { editor.deleteSelectedShape() }
                .disabled(editor.selectedShape == nil)
                .keyboardShortcut(.delete, modifiers: [])
            Button("Done") { editor.tool = .none }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Named versions of the photo's edits.
struct VersionsList: View {
    @Bindable var editor: PhotoEditor
    @State private var naming = false
    @State private var name = ""
    @State private var renaming: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(editor.versions) { v in
                HStack {
                    if renaming == v.id {
                        TextField("Name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { editor.renameVersion(v.id, to: name); renaming = nil }
                    } else {
                        Button { editor.useVersion(v.id) } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.name).lineLimit(1)
                                Text(v.created.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Switch to this version (you can undo)")
                    }
                    Menu {
                        Button("Rename…") { name = v.name; renaming = v.id }
                        Button("Delete Version", role: .destructive) { editor.deleteVersion(v.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .accessibilityLabel("More for \(v.name)")
                }
                .padding(6)
                .background(editor.history.current == v.recipe ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
            }
            if naming {
                HStack {
                    TextField("Version name", text: $name).textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                }
            } else {
                Button { name = ""; naming = true } label: { Label("Save Version…", systemImage: "square.on.square") }
                    .controlSize(.small)
                    .disabled(!editor.isEdited)
                    .help("Keep these edits under a name, so you can try something else and come back")
            }
        }
    }

    private func save() {
        editor.saveVersion(named: name)
        naming = false
    }
}
