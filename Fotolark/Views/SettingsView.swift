import FotolarkKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            FoldersSettings(model: model)
                .tabItem { Label("Folders", systemImage: "folder") }
            ExportSettings(model: model)
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 480)
        .padding(20)
    }
}

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @AppStorage("neutralGrayBackground") private var neutralGray = false

    var body: some View {
        Form {
            Picker("Save edits", selection: $model.storesEditsInLibrary) {
                Text("In a small file beside each photo").tag(false)
                Text("Inside Fotolark only").tag(true)
            }
            .pickerStyle(.radioGroup)
            Text(model.storesEditsInLibrary
                 ? "Edits stay in Fotolark’s own storage on this Mac. Photo folders stay tidy, but edits don’t follow photos copied elsewhere."
                 : "Each photo’s edits are saved in a .fotolark file next to it, so they travel with the photo when you copy the folder. Originals are never changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Neutral gray background while editing", isOn: $neutralGray)

            Toggle("Read text in photos so search can find it", isOn: $model.readsTextInPhotos)
            Text("Signs, documents and screenshots become searchable. This runs quietly in the background on this Mac; nothing leaves it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Also save tags inside the photo files", isOn: $model.writesTagsToFiles)
            Text("Other photo apps can then see your tags. This rewrites the details stored in each file, never the picture, and keeps a backup. Ratings and flags stay with Fotolark’s edits.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Section("Your edit presets") {
                if model.editPresets.isEmpty {
                    Text("Save one from the Effects section while editing.").foregroundStyle(.secondary)
                }
                ForEach(model.editPresets) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Button("Delete") { model.deleteEditPreset(preset.id) }
                    }
                }
            }
        }
    }
}

private struct FoldersSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fotolark shows these folders in the sidebar and updates them when photos change in Finder.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.library.roots) { root in
                    HStack {
                        Image(systemName: model.library.isAvailable(root) ? "folder" : "exclamationmark.triangle")
                        VStack(alignment: .leading) {
                            Text(model.library.name(of: root))
                            Text(root.path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { model.library.remove(root.id) }
                            .help("Stop showing this folder. Nothing is deleted.")
                    }
                }
            }
            .frame(minHeight: 180)
            Button("Add Folder…") { model.addFolderWithPanel() }
        }
    }
}

private struct ExportSettings: View {
    @Bindable var model: AppModel
    @AppStorage("export.metadata") private var metadata: MetadataPolicy = .keepAll
    @AppStorage("export.format") private var format: ExportFormat = .jpeg
    @AppStorage("export.quality") private var quality = 0.9
    @AppStorage("export.colorSpace") private var colorSpace: ExportColorSpace = .sRGB

    var body: some View {
        Form {
            Picker("Default format", selection: $format) {
                ForEach(ImageExporter.availableFormats) { Text($0.displayName).tag($0) }
            }
            LabeledContent("Default quality") {
                HStack {
                    Slider(value: $quality, in: 0.4...1).accessibilityLabel("Default quality")
                    Text("\(Int((quality * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("Default color", selection: $colorSpace) {
                ForEach(ExportColorSpace.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Photo details", selection: $metadata) {
                ForEach(MetadataPolicy.allCases) { Text($0.displayName).tag($0) }
            }
            Section("Your presets") {
                if model.customPresets.isEmpty {
                    Text("Use “Save as Preset…” in the Export window to add your own.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.customPresets) { preset in
                    HStack {
                        Text(preset.name)
                        Spacer()
                        Button("Delete") { model.deleteExportPreset(preset.id) }
                    }
                }
            }
        }
    }
}
