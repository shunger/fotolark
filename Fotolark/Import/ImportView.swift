import AppKit
import FotolarkKit
import SwiftUI

/// Choose photos on a phone, camera, card or drive and copy them into a folder.
struct ImportView: View {
    @Bindable var model: AppModel
    let source: any ImportSource

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", new = "New only", dates = "Date range"
        var id: String { rawValue }
    }

    @State private var filter = Filter.new
    @State private var from = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @State private var to = Date()
    @State private var selection: Set<ImportCandidate.ID> = []
    @State private var options = ImportView.savedOptions
    @State private var destination: URL?
    @State private var useDateFolders = true
    @State private var dateStyle = DateFolderPattern.Style.yearThenDay
    @State private var eventName = ""
    @State private var renameOn = false
    @State private var renamePattern = "{date}-{number}"
    @State private var deleteAfter = false
    @State private var confirmingDelete = false
    @AppStorage("import.thumbSize") private var thumbSize = 150.0

    private var photos: [ImportCandidate] {
        source.candidates.filter(\.isPhoto).filter { c in
            switch filter {
            case .all: return true
            case .new: return !model.importHistory.contains(c)
            case .dates:
                guard let d = c.date else { return false }
                return d >= Calendar.current.startOfDay(for: from) && d < Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to))!
            }
        }
    }

    private var videoCount: Int { source.candidates.filter { !$0.isPhoto }.count }

    /// Selected photos, or all shown if none are selected.
    private var chosen: [ImportCandidate] {
        let shown = photos
        let picked = shown.filter { selection.contains($0.id) }
        return picked.isEmpty ? shown : picked
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            Divider()
            optionsPanel.frame(width: 300)
        }
        .onAppear {
            if destination == nil { destination = model.library.resolvedURLs[model.library.roots.first?.id ?? UUID()] }
        }
        .alert("Delete from \(source.title) after importing?", isPresented: $confirmingDelete) {
            Button("Import and Delete", role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each photo is deleted only after its copy on this Mac has been checked. Photos that can’t be checked stay on \(source.title).")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: source.systemImage).font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Import from \(source.title)").font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if filter == .dates {
                DatePicker("From", selection: $from, displayedComponents: .date).labelsHidden()
                DatePicker("To", selection: $to, displayedComponents: .date).labelsHidden()
            }
            Slider(value: $thumbSize, in: 90...260).frame(width: 90).accessibilityLabel("Thumbnail size")
        }
        .padding(12)
    }

    private var summary: String {
        if source.isLoading { return "Reading photos…" }
        var parts = ["\(photos.count) shown"]
        if !selection.isEmpty { parts.append("\(selection.count) selected") }
        if videoCount > 0 { parts.append("\(videoCount) videos not shown (video import comes later)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let message = source.statusMessage {
            VStack(spacing: 12) {
                if source.isLoading { ProgressView() }
                Text(message).font(.title3).multilineTextAlignment(.center).frame(maxWidth: 420)
                if source.systemImage == "camera" {
                    Text("Android phones show up only in “Transfer photos (PTP)” USB mode.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbSize), spacing: 10)], spacing: 10) {
                    ForEach(photos) { c in
                        ImportCell(source: source, candidate: c, isSelected: selection.contains(c.id),
                                   alreadyImported: model.importHistory.contains(c), size: thumbSize)
                            .onTapGesture {
                                if selection.contains(c.id) { selection.remove(c.id) } else { selection.insert(c.id) }
                            }
                    }
                }
                .padding(12)
            }
        }
    }

    private var optionsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Copy to").font(.headline)
                Menu(destination?.lastPathComponent ?? "Choose a folder") {
                    ForEach(model.library.roots) { root in
                        if let url = model.library.resolvedURLs[root.id] {
                            Button(model.library.name(of: root)) { destination = url }
                        }
                    }
                    Divider()
                    Button("Choose…") { chooseDestination() }
                }
                Toggle("Sort into folders by date taken", isOn: $useDateFolders)
                if useDateFolders {
                    Picker("Folders", selection: $dateStyle) {
                        ForEach(DateFolderPattern.Style.allCases) { Text($0.example).tag($0) }
                    }
                    TextField("Event name, e.g. Beach", text: $eventName)
                }

                Divider()
                Toggle("Rename as they come in", isOn: $renameOn)
                if renameOn {
                    TextField("Pattern", text: $renamePattern)
                    Text("Use {date}, {time}, {number} and {name}.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Convert HEIC to JPEG", isOn: $options.convertHEICToJPEG)
                if options.convertHEICToJPEG {
                    Toggle("Keep the HEIC original too", isOn: $options.keepHEICOriginal)
                }
                Toggle("Skip photos already imported", isOn: $options.skipDuplicates)

                Divider()
                Toggle("Delete from \(source.title) after importing", isOn: $deleteAfter)
                    .disabled(!source.canDelete)
                Text(source.canDelete
                     ? "Only photos whose copies check out are deleted."
                     : "\(source.title) doesn’t allow deleting from here.")
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    if deleteAfter { confirmingDelete = true } else { start() }
                } label: {
                    Text(chosen.count == 1 ? "Import 1 Photo" : "Import \(chosen.count) Photos").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty || destination == nil || source.statusMessage != nil)
                if destination == nil {
                    Text("Choose where the photos go.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where imported photos go. Fotolark adds this folder to the sidebar."
        if panel.runModal() == .OK, let url = panel.url {
            model.library.add(url)
            destination = url
        }
    }

    private func start() {
        guard let destination else { return }
        var o = options
        o.dateFolders = useDateFolders ? DateFolderPattern(style: dateStyle, eventName: eventName) : nil
        if renameOn {
            var rule = RenameRule()
            rule.pattern = renamePattern
            o.rename = rule
        } else {
            o.rename = nil
        }
        Self.savedOptions = o
        model.runImport(chosen, from: source, options: o, to: destination, deleteAfter: deleteAfter)
        selection = []
    }

    static var savedOptions: ImportOptions {
        get {
            guard let data = UserDefaults.standard.data(forKey: "import.options"),
                  let o = try? JSONDecoder().decode(ImportOptions.self, from: data) else { return ImportOptions() }
            return o
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "import.options") }
    }
}

private struct ImportCell: View {
    let source: any ImportSource
    let candidate: ImportCandidate
    let isSelected: Bool
    let alreadyImported: Bool
    let size: Double

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = source.thumbnail(for: candidate.id) {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                    }
                }
                .frame(width: size, height: size * 0.75)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(4)
                } else if alreadyImported {
                    Text("Imported").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.regularMaterial, in: Capsule())
                        .padding(4)
                }
            }
            Text(candidate.name).font(.caption).lineLimit(1).truncationMode(.middle)
            if let date = candidate.date {
                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onAppear { source.requestThumbnail(for: candidate.id) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Selects this photo for importing")
    }
}
