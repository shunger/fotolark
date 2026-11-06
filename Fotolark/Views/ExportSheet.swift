import AppKit
import FotolarkKit
import SwiftUI

/// Export settings, then a save panel (one photo) or a folder (several). Always writes
/// new files; originals are untouched.
struct ExportSheet: View {
    @Bindable var model: AppModel
    /// The photos to export, with their edits.
    let photos: [URL]
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.format") private var format: ExportFormat = .jpeg
    @AppStorage("export.quality") private var quality = 0.9
    @AppStorage("export.colorSpace") private var colorSpace: ExportColorSpace = .sRGB
    @AppStorage("export.metadata") private var metadata: MetadataPolicy = .keepAll
    /// 0 = full size.
    @AppStorage("export.longestSide") private var longestSide = 0
    @AppStorage("export.watermarkOn") private var watermarkOn = false
    @AppStorage("export.watermark") private var watermarkData = Data()
    @State private var newPresetName = ""
    @State private var isNaming = false

    private var options: ExportOptions {
        ExportOptions(format: format, quality: quality, colorSpace: colorSpace, metadata: metadata,
                      maxLongestSide: longestSide > 0 ? longestSide : nil, watermark: watermarkOn ? watermark : nil)
    }

    private var watermark: Watermark {
        get { (try? JSONDecoder().decode(Watermark.self, from: watermarkData)) ?? Watermark() }
        nonmutating set { watermarkData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    private func watermarkBinding<T>(_ key: WritableKeyPath<Watermark, T>) -> Binding<T> {
        Binding(get: { watermark[keyPath: key] }, set: { var w = watermark; w[keyPath: key] = $0; watermark = w })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(photos.count == 1 ? "Export a copy" : "Export \(photos.count) photos").font(.title2.weight(.semibold))
            Text("Saves edited copies as new files. The originals stay as they are.")
                .foregroundStyle(.secondary)

            Form {
                Picker("Preset", selection: Binding(get: { matchingPreset?.id }, set: { id in
                    if let p = model.exportPresets.first(where: { $0.id == id }) { apply(p.options) }
                })) {
                    if matchingPreset == nil { Text("Custom").tag(UUID?.none) }
                    ForEach(model.exportPresets) { Text($0.name).tag(UUID?.some($0.id)) }
                }
                Picker("Format", selection: $format) {
                    ForEach(ImageExporter.availableFormats) { Text($0.displayName).tag($0) }
                }
                if format.isLossy {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.4...1).accessibilityLabel("Quality")
                            Text("\(Int((quality * 100).rounded()))%").monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Picker("Size", selection: $longestSide) {
                    Text(sizeLabel).tag(0)
                    ForEach([3840, 2048, 1600, 1024, 640], id: \.self) { Text("Longest side \($0) px").tag($0) }
                }
                Picker("Color", selection: $colorSpace) {
                    ForEach(ExportColorSpace.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Photo details", selection: $metadata) {
                    ForEach(MetadataPolicy.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Add a watermark", isOn: $watermarkOn)
                if watermarkOn {
                    if let logo = watermark.logoPath {
                        LabeledContent("Logo") {
                            HStack {
                                Text(URL(fileURLWithPath: logo).lastPathComponent).lineLimit(1)
                                Button("Use Text Instead") { watermarkBinding(\.logoPath).wrappedValue = nil }
                            }
                        }
                    } else {
                        LabeledContent("Text") {
                            HStack {
                                TextField("© Your Name", text: watermarkBinding(\.text))
                                Button("Use a Logo…") { chooseLogo() }
                            }
                        }
                    }
                    Picker("Position", selection: watermarkBinding(\.position)) {
                        ForEach(Watermark.Position.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("Size") { Slider(value: watermarkBinding(\.size), in: 0.02...0.25).accessibilityLabel("Watermark size") }
                    LabeledContent("Opacity") { Slider(value: watermarkBinding(\.opacity), in: 0.1...1).accessibilityLabel("Watermark opacity") }
                }
            }
            .formStyle(.columns)

            if isNaming {
                HStack {
                    TextField("Preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePreset)
                    Button("Save", action: savePreset).disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { isNaming = false }
                }
            }

            HStack {
                if !isNaming && matchingPreset == nil {
                    Button("Save as Preset…") { isNaming = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseDestination() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(photos.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.message = "Choose a logo. A PNG with a transparent background works best."
        guard panel.runModal() == .OK, let url = panel.url, let path = model.importLogo(from: url) else { return }
        watermarkBinding(\.logoPath).wrappedValue = path
    }

    private var sizeLabel: String {
        if photos.count == 1, let editor = model.editor, editor.url == photos[0] {
            return "Full size (\(editor.outputSize.description) px)"
        }
        return "Full size"
    }

    private var matchingPreset: ExportPreset? {
        model.exportPresets.first { $0.options == options }
    }

    private func apply(_ o: ExportOptions) {
        format = o.format
        quality = o.quality
        colorSpace = o.colorSpace
        metadata = o.metadata
        longestSide = o.maxLongestSide ?? 0
    }

    private func savePreset() {
        let name = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.saveExportPreset(ExportPreset(name: name, options: options))
        isNaming = false
        newPresetName = ""
    }

    private func chooseDestination() {
        let options = options
        if photos.count == 1 {
            let photo = photos[0]
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format.utType]
            panel.canCreateDirectories = true
            panel.directoryURL = photo.deletingLastPathComponent()
            panel.nameFieldStringValue = ImageExporter.fileName(for: photo, format: format, suffix: " edited")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            dismiss()
            model.exportOne(photo, options: options, to: url)
        } else {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.message = "Choose a folder for the \(photos.count) exported photos."
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            dismiss()
            model.exportMany(photos, options: options, to: folder)
        }
    }
}
