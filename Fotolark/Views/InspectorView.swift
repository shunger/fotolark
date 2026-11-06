import FotolarkKit
import SwiftUI

/// The editing panel: one-click fixes first, fine controls below.
struct InspectorView: View {
    @Bindable var editor: PhotoEditor
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch editor.tool {
                case .crop: CropPanel(editor: editor)
                case .straighten: StraightenPanel(editor: editor)
                case .whiteBalance: WhiteBalancePanel(editor: editor)
                case .redEye: RedEyePanel(editor: editor)
                case .retouch: RetouchPanel(editor: editor)
                case .text: TextPanel(editor: editor)
                case .focus:
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Focal B&W").font(.headline)
                        Text("Click the part of the photo to keep in color. The rest turns black and white.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Done") { editor.tool = .none }.keyboardShortcut(.defaultAction).controlSize(.large)
                    }
                case .none: mainPanels
                }
            }
            .padding(16)
        }
        .scrollIndicators(.automatic)
        .disabled(!editor.isLoaded)
    }

    @ViewBuilder
    private var mainPanels: some View {
        InspectorSection("Basic fixes") {
            VStack(spacing: 6) {
                FixButton(title: "Magic fix", systemImage: "wand.and.stars", isOn: editor.has(.magicFix),
                          help: "Fixes exposure, contrast and color in one click") {
                    editor.toggleAutoFix(.magicFix)
                }
                HStack(spacing: 6) {
                    FixButton(title: "Auto contrast", systemImage: "circle.lefthalf.filled", isOn: editor.has(.autoContrast),
                              help: "Stretches the darkest and brightest tones") {
                        editor.toggleAutoFix(.autoContrast)
                    }
                    FixButton(title: "Auto color", systemImage: "paintpalette", isOn: editor.has(.autoColor),
                              help: "Removes a color cast") {
                        editor.toggleAutoFix(.autoColor)
                    }
                }
            }
            FixButton(title: "Neutral color picker", systemImage: "eyedropper", isOn: editor.has(.whiteBalance),
                      help: "Click something in the photo that should be gray or white to remove a color cast") {
                if editor.has(.whiteBalance) {
                    editor.apply(editor.recipe.removing(.whiteBalance), label: "Remove white balance")
                } else {
                    editor.beginWhiteBalance()
                }
            }
            FixButton(title: "Retouch", systemImage: "bandage", isOn: editor.has(.retouch),
                      help: "Remove spots and blemishes, copy one area over another, or soften skin") {
                editor.beginRetouch()
            }
            FixButton(title: "Red-eye", systemImage: "eye", isOn: editor.has(.redEye),
                      help: "Finds and fixes red eyes from the camera flash; click any it misses") {
                editor.beginRedEye()
            }
            SliderRow(editor: editor, title: "Fill light", key: \.fillLight, range: 0...1, format: "%.0f")
        }

        InspectorSection("Crop and rotate") {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    ToolButton(title: "Crop", systemImage: "crop") { editor.beginCrop(); model.zoomToFit() }
                    ToolButton(title: "Straighten", systemImage: "level") { editor.tool = .straighten; model.zoomToFit() }
                }
                GridRow {
                    ToolButton(title: "Rotate left", systemImage: "rotate.left") { editor.rotate(clockwise: false) }
                    ToolButton(title: "Rotate right", systemImage: "rotate.right") { editor.rotate(clockwise: true) }
                }
                GridRow {
                    ToolButton(title: "Text", systemImage: "textformat") { editor.tool = .text; model.zoomToFit() }
                    ToolButton(title: "Flip vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                        editor.flip(horizontally: false)
                    }
                }
                GridRow {
                    ToolButton(title: "Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        editor.flip(horizontally: true)
                    }
                    ToolButton(title: "Resize…", systemImage: "arrow.up.left.and.arrow.down.right") { model.sheet = .resize }
                }
            }
            LabeledContent("Size", value: sizeText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        InspectorSection("Effects") {
            EffectsControls(editor: editor, model: model)
        }

        InspectorSection("Light") {
            HistogramView(histogram: editor.histogram)
            SliderRow(editor: editor, title: "Exposure", key: \.exposure, range: -3...3, format: "%+.2f")
            SliderRow(editor: editor, title: "Brightness", key: \.brightness)
            SliderRow(editor: editor, title: "Contrast", key: \.contrast)
            SliderRow(editor: editor, title: "Highlights", key: \.highlights)
            SliderRow(editor: editor, title: "Shadows", key: \.shadows)
            SliderRow(editor: editor, title: "Whites", key: \.whites)
            SliderRow(editor: editor, title: "Blacks", key: \.blacks)
        }

        InspectorSection("Color") {
            SliderRow(editor: editor, title: "Warmth", key: \.temperature)
            SliderRow(editor: editor, title: "Tint", key: \.tint)
            SliderRow(editor: editor, title: "Saturation", key: \.saturation)
            SliderRow(editor: editor, title: "Vibrance", key: \.vibrance)
        }

        InspectorSection("Detail") {
            SliderRow(editor: editor, title: "Sharpness", key: \.sharpness, range: 0...1, format: "%.0f")
            SliderRow(editor: editor, title: "Clarity", key: \.clarity)
            SliderRow(editor: editor, title: "Structure", key: \.structure)
            SliderRow(editor: editor, title: "Noise reduction", key: \.noiseReduction, range: 0...1, format: "%.0f")
            SliderRow(editor: editor, title: "Color noise", key: \.colorNoiseReduction, range: 0...1, format: "%.0f")
        }

        DisclosureSection("Curves") { CurvesEditor(editor: editor) }
        DisclosureSection("Levels") { LevelsControls(editor: editor) }
        DisclosureSection("Color ranges") { ColorRangeControls(editor: editor) }

        InspectorSection("Vignette") {
            SliderRow(editor: editor, title: "Amount", key: \.vignette)
            SliderRow(editor: editor, title: "Size", key: \.vignetteSize, range: 0...1, format: "%.0f", defaultValue: 0.5)
        }

        InspectorSection("History") {
            HistoryList(editor: editor)
        }
    }

    private var sizeText: String {
        let size = editor.outputSize
        return editor.recipe.resize == nil ? "\(size) px" : "\(size) px (resized)"
    }
}

/// A titled group in the inspector.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}

/// A one-click fix that shows a check mark while it's applied; clicking again removes it.
private struct FixButton: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 4)
                if isOn { Image(systemName: "checkmark").fontWeight(.semibold) }
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : nil)
        .help(isOn ? "\(help). Click again to remove it." : help)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

private struct ToolButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
        .buttonStyle(.bordered)
    }
}

/// A labeled slider. Double-click the name to reset it.
struct SliderRow: View {
    @Bindable var editor: PhotoEditor
    let title: String
    let key: WritableKeyPath<Adjustments, Double>
    var range: ClosedRange<Double> = -1...1
    var format = "%+.0f"
    /// Value a double-click on the name resets to.
    var defaultValue = 0.0

    var body: some View {
        let value = editor.adjustment(key)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2) { editor.setAdjustment(key, to: defaultValue, label: title) }
                    .help("Double-click to reset")
                Spacer()
                Text(display(value))
                    .monospacedDigit()
                    .foregroundStyle(value == 0 ? .secondary : .primary)
            }
            .font(.callout)
            Slider(value: Binding(get: { value }, set: { editor.setAdjustment(key, to: $0, label: title) }),
                   in: range) { editing in
                if !editing { editor.commitPending() }
            }
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityValue(display(value))
            .accessibilityAction(named: "Reset") { editor.setAdjustment(key, to: defaultValue, label: title) }
        }
    }

    /// Exposure shows stops; the other sliders show −100…+100.
    private func display(_ v: Double) -> String {
        if range.upperBound > 1 { return String(format: format, v) }
        let scaled = (v * 100).rounded()
        return scaled == 0 ? "0" : String(format: format, scaled)
    }
}

struct HistoryList: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(editor.history.entries.enumerated()), id: \.element.id) { i, entry in
                let isCurrent = i == editor.history.index
                Button {
                    editor.jump(to: entry.id)
                } label: {
                    HStack {
                        Text(entry.label)
                            .foregroundStyle(i > editor.history.index ? .secondary : .primary)
                        Spacer()
                        if isCurrent { Image(systemName: "arrow.left").font(.caption) }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(isCurrent ? Color.accentColor.opacity(0.18) : .clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .font(.callout)
    }
}

/// Shown in the inspector while the crop tool is active.
struct CropPanel: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Crop").font(.headline)
            Text("Drag the corners or edges. Drag inside to move the crop.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Shape", selection: $editor.cropAspect) {
                ForEach(CropAspect.allCases) { Text($0.title).tag($0) }
            }
            if editor.cropAspect == .custom {
                HStack {
                    TextField("Width", value: $editor.customAspectWidth, format: .number)
                        .frame(width: 60)
                    Text("by")
                    TextField("Height", value: $editor.customAspectHeight, format: .number)
                        .frame(width: 60)
                }
            }
            if editor.cropAspect != .free && editor.cropAspect != .square {
                Picker("Orientation", selection: $editor.cropPortrait) {
                    Text("Landscape").tag(false)
                    Text("Portrait").tag(true)
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Button("Suggest Crop") { editor.suggestCrop() }
                    .help("Frames the main subject, keeping the photo's shape")
                Button("Reset") { editor.cropDraft = .full; editor.cropAspect = .free }
            }
            if let message = editor.toolMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) { editor.cancelCrop() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { editor.applyCrop() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }
}

/// Shown in the inspector while straightening.
struct StraightenPanel: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        let degrees = editor.recipe.straightenDegrees
        VStack(alignment: .leading, spacing: 14) {
            Text("Straighten").font(.headline)
            Text("Line up the grid with the horizon or a wall. The photo is trimmed slightly so no blank corners show.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Auto-Straighten") { editor.autoStraighten() }
                .help("Levels the horizon automatically")
            if let message = editor.toolMessage {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Angle")
                Spacer()
                Text(String(format: "%+.1f°", degrees)).monospacedDigit()
            }
            Slider(value: Binding(get: { degrees }, set: { editor.setStraighten($0) }), in: -45...45) { editing in
                if !editing { editor.commitPending() }
            }
            .accessibilityLabel("Straighten angle")
            HStack {
                Button { editor.setStraighten(degrees - 0.1); editor.commitPending() } label: { Image(systemName: "minus") }
                    .accessibilityLabel("Turn left 0.1 degrees")
                Button { editor.setStraighten(degrees + 0.1); editor.commitPending() } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Turn right 0.1 degrees")
                Spacer()
                Button("Reset") { editor.setStraighten(0); editor.commitPending() }
            }
            Button("Done") { editor.tool = .none }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Shown while the neutral color picker is active.
struct WhiteBalancePanel: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Neutral color picker").font(.headline)
            Text("Click something in the photo that should be gray or white, such as a cloud, a wall or a shirt. Fotolark removes the color cast to match.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let message = editor.whiteBalanceMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Cancel") { editor.tool = .none }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
    }
}

/// Red, green and blue tone distribution, with the overall brightness in gray.
struct HistogramView: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            guard let h = histogram else { return }
            func path(_ values: [Double]) -> Path {
                var p = Path()
                let n = values.count
                p.move(to: CGPoint(x: 0, y: size.height))
                for (i, v) in values.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(max(n - 1, 1))
                    p.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v))))
                }
                p.addLine(to: CGPoint(x: size.width, y: size.height))
                p.closeSubpath()
                return p
            }
            context.fill(path(h.luminance), with: .color(.gray.opacity(0.45)))
            context.blendMode = .plusLighter
            context.fill(path(h.red), with: .color(.red.opacity(0.45)))
            context.fill(path(h.green), with: .color(.green.opacity(0.45)))
            context.fill(path(h.blue), with: .color(.blue.opacity(0.45)))
        }
        .frame(height: 64)
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(summary)
    }

    /// Spoken summary: where most tones sit.
    private var summary: String {
        guard let l = histogram?.luminance, !l.isEmpty else { return "Not available" }
        let third = l.count / 3
        let parts = [l[..<third].reduce(0, +), l[third..<(2 * third)].reduce(0, +), l[(2 * third)...].reduce(0, +)]
        let names = ["mostly dark tones", "mostly middle tones", "mostly bright tones"]
        return names[parts.firstIndex(of: parts.max()!)!]
    }
}

/// A section that can be folded away, for the less-used tools. Remembers its state.
struct DisclosureSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @AppStorage private var isExpanded: Bool

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        _isExpanded = AppStorage(wrappedValue: false, "section.\(title)")
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content.padding(.top, 6)
        } label: {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader)
        }
    }
}

/// Shown while the red-eye tool is open.
struct RedEyePanel: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Red-eye").font(.headline)
            Text(editor.toolMessage ?? "Click a red eye in the photo to fix it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !editor.redEyeSpots.isEmpty {
                Button("Remove All Red-Eye Fixes") {
                    editor.apply(editor.recipe.removing(.redEye), label: "Remove red-eye")
                }
            }
            Button("Done") { editor.tool = .none }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// Shown while retouching.
struct RetouchPanel: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Retouch").font(.headline)
            Picker("Tool", selection: $editor.retouchTool) {
                Text("Spot heal").tag(RetouchStroke.Tool.heal)
                Text("Clone").tag(RetouchStroke.Tool.clone)
                Text("Soften skin").tag(RetouchStroke.Tool.soften)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(help)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text("Brush size"); Spacer(); Text("\(Int(editor.brushSize))").monospacedDigit() }.font(.callout)
                Slider(value: $editor.brushSize, in: 4...150).controlSize(.small).accessibilityLabel("Brush size")
            }
            if editor.retouchTool == .soften {
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text("Strength"); Spacer(); Text("\(Int(editor.softenStrength * 100))").monospacedDigit() }.font(.callout)
                    Slider(value: $editor.softenStrength, in: 0.1...1).controlSize(.small).accessibilityLabel("Soften strength")
                }
            }
            if let message = editor.toolMessage {
                Label(message, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text("Tip: zoom in (⌘=) for small spots.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Undo Last Stroke") { editor.undoLastStroke() }
                    .disabled(editor.retouchStrokes.isEmpty)
                Spacer()
                Button("Done") { editor.tool = .none }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }

    private var help: String {
        switch editor.retouchTool {
        case .heal: "Click a spot or paint over a blemish. Fotolark fills it with nearby texture that matches the light around it."
        case .clone: "⌥-click (Option-click) the area to copy from, then paint where it should go."
        case .soften: "Paint over skin to smooth it gently. Leave eyes, lips and hair sharp."
        }
    }
}
