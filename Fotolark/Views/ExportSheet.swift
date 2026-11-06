import AppKit
import FotolarkKit
import SwiftUI

/// Export settings, then a save panel. Always writes a new file; the original is untouched.
struct ExportSheet: View {
    @Bindable var editor: PhotoEditor
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.format") private var format: ExportFormat = .jpeg
    @AppStorage("export.quality") private var quality = 0.9
    @AppStorage("export.colorSpace") private var colorSpace: ExportColorSpace = .sRGB

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export a copy").font(.title2.weight(.semibold))
            Text("Saves the edited photo as a new file. The original stays as it is.")
                .foregroundStyle(.secondary)

            Form {
                Picker("Format", selection: $format) {
                    ForEach(ImageExporter.availableFormats) { Text($0.displayName).tag($0) }
                }
                if format.isLossy {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $quality, in: 0.4...1)
                                .accessibilityLabel("Quality")
                            Text("\(Int((quality * 100).rounded()))%")
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                Picker("Color", selection: $colorSpace) {
                    ForEach(ExportColorSpace.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent("Size") {
                    HStack {
                        Text("\(editor.outputSize.description) px").monospacedDigit()
                        Button("Change…") {
                            dismiss()
                            Task { @MainActor in model.sheet = .resize }
                        }
                    }
                }
            }
            .formStyle(.columns)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseDestination() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.directoryURL = editor.url.deletingLastPathComponent()
        let base = editor.url.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base) edited.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let options = ExportOptions(format: format, quality: quality, colorSpace: colorSpace)
        dismiss()
        Task {
            do {
                try await editor.export(options: options, to: url)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
