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
            SliderRow(editor: editor, title: "Fill light", key: \.fillLight, range: 0...1)
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

        InspectorSection("Light") {
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

    var body: some View {
        let value = editor.adjustment(key)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2) { editor.setAdjustment(key, to: 0, label: title) }
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

            Button("Reset crop") { editor.cropDraft = .full; editor.cropAspect = .free }

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
