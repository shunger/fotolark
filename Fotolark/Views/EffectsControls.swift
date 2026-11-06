import AppKit
import FotolarkKit
import SwiftUI

/// One-click looks with previews, each applied look with its strength, and presets.
struct EffectsControls: View {
    @Bindable var editor: PhotoEditor
    @Bindable var model: AppModel
    @State private var isNamingPreset = false
    @State private var presetName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
                ForEach(Look.Kind.allCases) { kind in
                    Button { editor.addLook(kind) } label: {
                        VStack(spacing: 3) {
                            Group {
                                if let cg = editor.lookPreviews[kind] {
                                    Image(decorative: cg, scale: 1).resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(.quaternary)
                                }
                            }
                            .frame(width: 76, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(kind.title).font(.caption2).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Add \(kind.title)")
                    .accessibilityLabel("Add \(kind.title) look")
                }
            }

            ForEach(editor.recipe.looks) { look in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(look.kind.title).font(.callout.weight(.medium))
                        Spacer()
                        if look.kind == .focalBW {
                            Button("Move…") { editor.tool = .focus }
                                .controlSize(.small)
                                .help("Click the photo to choose what stays in color")
                        }
                        Button { editor.removeLook(look) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Remove \(look.kind.title)")
                    }
                    slider("Strength", value: look.strength) { v in var l = look; l.strength = v; editor.updateLook(l) }
                    if look.kind == .focalBW {
                        slider("Size", value: look.focusRadius, range: 0.05...0.7) { v in
                            var l = look; l.focusRadius = v; editor.updateLook(l)
                        }
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Menu("Presets") {
                    if model.editPresets.isEmpty {
                        Text("No presets yet")
                    }
                    ForEach(model.editPresets) { preset in
                        Button(preset.name) { editor.paste(preset.recipe) }
                    }
                    Divider()
                    Button("Save Current Settings as Preset…") { isNamingPreset = true }
                        .disabled(editor.recipe.pastableEdits.isEmpty)
                }
                .fixedSize()
                .help("Apply a saved combination of settings, or save this photo's")
            }
            if isNamingPreset {
                HStack {
                    TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder).onSubmit(savePreset)
                    Button("Save", action: savePreset).disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { isNamingPreset = false }
                }
                Text("Saves tone, color and looks (not crop, turns, retouching or text).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.saveEditPreset(EditPreset(name: name, recipe: editor.recipe))
        presetName = ""
        isNamingPreset = false
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double> = 0...1,
                        set: @escaping @Sendable @MainActor (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range) { if !$0 { editor.commitPending() } }
                .controlSize(.mini)
                .accessibilityLabel(title)
            Text("\(Int((value * 100).rounded()))").font(.caption).monospacedDigit().frame(width: 28, alignment: .trailing)
        }
    }
}

/// Click to place the focal B&W spot.
struct FocusOverlay: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        GeometryReader { geo in
            let longest = max(geo.size.width, geo.size.height)
            ZStack {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        editor.setFocus(atDisplayPoint: CGPoint(x: p.x / geo.size.width, y: p.y / geo.size.height))
                    }
                if let f = editor.focusDisplay {
                    Circle()
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .shadow(color: .black.opacity(0.6), radius: 1)
                        .frame(width: f.radius * longest * 2, height: f.radius * longest * 2)
                        .position(x: f.point.x * geo.size.width, y: f.point.y * geo.size.height)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel("Click what should stay in color")
    }
}

/// Click to add a caption; drag a caption to move it.
struct TextOverlayEditor: View {
    @Bindable var editor: PhotoEditor
    @State private var dragStart: (id: UUID, x: Double, y: Double)?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        if let hit = hitTest(p, in: size) {
                            editor.selectedTextID = hit.id
                        } else {
                            editor.addText(atDisplayPoint: CGPoint(x: p.x / size.width, y: p.y / size.height))
                        }
                    }
                ForEach(editor.textOverlays) { o in
                    let box = frame(of: o, in: size)
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(o.id == editor.selectedTextID ? Color.accentColor : Color.white.opacity(0.7),
                                      style: StrokeStyle(lineWidth: 1.5, dash: o.id == editor.selectedTextID ? [] : [4, 3]))
                        .contentShape(Rectangle())
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { v in
                                    editor.selectedTextID = o.id
                                    let start = dragStart?.id == o.id ? dragStart! : (o.id, o.x, o.y)
                                    dragStart = start
                                    var moved = o
                                    moved.x = min(max(start.x + v.translation.width / size.width, 0), 1)
                                    moved.y = min(max(start.y + v.translation.height / size.height, 0), 1)
                                    editor.updateText(moved)
                                }
                                .onEnded { _ in dragStart = nil; editor.commitPending() }
                        )
                        .onTapGesture { editor.selectedTextID = o.id }
                        .accessibilityLabel("Caption: \(o.text)")
                }
            }
        }
    }

    /// Approximate box of a caption on screen (for selecting and dragging).
    private func frame(of o: TextOverlay, in size: CGSize) -> CGRect {
        let h = o.size * size.height
        let lines = o.text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 1
        let w = max(Double(longest) * h * 0.6, h)
        let height = h * 1.25 * Double(max(lines.count, 1))
        return CGRect(x: o.x * size.width - w / 2 - 6, y: o.y * size.height - height / 2 - 4, width: w + 12, height: height + 8)
    }

    private func hitTest(_ p: CGPoint, in size: CGSize) -> TextOverlay? {
        editor.textOverlays.last { frame(of: $0, in: size).contains(p) }
    }
}

/// Edits the selected caption.
struct TextPanel: View {
    @Bindable var editor: PhotoEditor

    static let fonts: [(name: String, title: String)] = [
        ("Helvetica-Bold", "Helvetica Bold"), ("Helvetica", "Helvetica"), ("AvenirNext-DemiBold", "Avenir Next"),
        ("Futura-Medium", "Futura"), ("Georgia", "Georgia"), ("Georgia-Italic", "Georgia Italic"),
        ("Baskerville", "Baskerville"), ("Didot", "Didot"), ("AmericanTypewriter", "American Typewriter"),
        ("Courier-Bold", "Courier"), ("MarkerFelt-Wide", "Marker Felt"), ("Noteworthy-Bold", "Noteworthy"),
        ("SnellRoundhand-Bold", "Snell Roundhand"), ("Impact", "Impact"),
    ]

    private var selected: TextOverlay? {
        editor.textOverlays.first { $0.id == editor.selectedTextID } ?? editor.textOverlays.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Text").font(.headline)
            Text("Click the photo to add a caption. Drag a caption to move it.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let o = selected {
                TextField("Caption", text: Binding(get: { o.text }, set: { var n = o; n.text = $0; editor.updateText(n) }),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                Picker("Font", selection: Binding(get: { o.fontName }, set: { var n = o; n.fontName = $0; editor.updateText(n, live: false) })) {
                    ForEach(Self.fonts, id: \.name) { Text($0.title).font(.custom($0.name, size: 13)).tag($0.name) }
                }
                HStack {
                    Text("Size").font(.callout)
                    Slider(value: Binding(get: { o.size }, set: { var n = o; n.size = $0; editor.updateText(n) }), in: 0.02...0.3) {
                        if !$0 { editor.commitPending() }
                    }
                    .accessibilityLabel("Text size")
                }
                HStack {
                    ColorPicker("Color", selection: colorBinding(o, \.color))
                    Spacer()
                    Picker("Align", selection: Binding(get: { o.alignment }, set: { var n = o; n.alignment = $0; editor.updateText(n, live: false) })) {
                        Image(systemName: "text.alignleft").tag(TextOverlay.Alignment.left)
                        Image(systemName: "text.aligncenter").tag(TextOverlay.Alignment.center)
                        Image(systemName: "text.alignright").tag(TextOverlay.Alignment.right)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Shadow", isOn: Binding(get: { o.shadow }, set: { var n = o; n.shadow = $0; editor.updateText(n, live: false) }))
                HStack {
                    Toggle("Outline", isOn: Binding(get: { o.outline }, set: { var n = o; n.outline = $0; editor.updateText(n, live: false) }))
                    if o.outline { ColorPicker("Outline color", selection: colorBinding(o, \.outlineColor)).labelsHidden() }
                }
                Button("Delete Caption", role: .destructive) {
                    editor.selectedTextID = o.id
                    editor.deleteSelectedText()
                }
            }
            Button("Done") { editor.tool = .none }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func colorBinding(_ o: TextOverlay, _ key: WritableKeyPath<TextOverlay, RGBAColor>) -> Binding<Color> {
        Binding(get: {
            let c = o[keyPath: key]
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }, set: { color in
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
            var n = o
            n[keyPath: key] = RGBAColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent, alpha: ns.alphaComponent)
            editor.updateText(n, live: false)
        })
    }
}
