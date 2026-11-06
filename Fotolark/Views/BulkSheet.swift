import AppKit
import FotolarkKit
import SwiftUI

enum BulkTool: String, CaseIterable, Identifiable {
    case convert, resize, rename, rotate, move

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: "Convert"
        case .resize: "Resize"
        case .rename: "Rename"
        case .rotate: "Rotate"
        case .move: "Move or Copy"
        }
    }

    var systemImage: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .resize: "arrow.up.left.and.arrow.down.right"
        case .rename: "character.cursor.ibeam"
        case .rotate: "rotate.right"
        case .move: "folder"
        }
    }
}

/// One window for every bulk tool. Each shows a preview before anything runs, then hands
/// the work to the job queue, where it can be paused, stopped and undone.
struct BulkSheet: View {
    @Bindable var model: AppModel
    let photos: [URL]
    @State var tool: BulkTool
    @Environment(\.dismiss) private var dismiss

    // Convert and resize
    @AppStorage("bulk.format") private var format: ExportFormat = .jpeg
    @AppStorage("bulk.sameFormat") private var sameFormat = false
    @AppStorage("bulk.quality") private var quality = 0.9
    @AppStorage("bulk.includeEdits") private var includeEdits = true
    @AppStorage("bulk.resizeByPercent") private var resizeByPercent = false
    @AppStorage("bulk.longestSide") private var longestSide = 1600
    @AppStorage("bulk.percent") private var percent = 50.0
    @AppStorage("bulk.allowEnlarging") private var allowEnlarging = false
    @State private var destination: URL?

    // Rename
    @State private var rule = RenameRule()
    @State private var preview: [RenamePreviewItem] = []
    @State private var dates: [URL: Date] = [:]

    // Rotate
    @State private var turns = 1

    // Move or copy
    @AppStorage("bulk.copy") private var copy = false
    @AppStorage("bulk.useDateFolders") private var useDateFolders = false
    @AppStorage("bulk.dateStyle") private var dateStyle: DateFolderPattern.Style = .yearThenDay
    @State private var eventName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Tool", selection: $tool) {
                ForEach(BulkTool.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Form { options }
                .formStyle(.columns)

            Text("Preview").font(.headline)
            previewList
                .frame(height: 170)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))

            HStack {
                Text("You can undo this from the bulk jobs list.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(runTitle, action: run)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRun)
            }
        }
        .padding(20)
        .frame(width: 580)
        .task {
            dates = model.datesTaken(for: photos)
            refreshRenamePreview()
        }
        .onChange(of: rule) { refreshRenamePreview() }
    }

    // MARK: Options

    @ViewBuilder
    private var options: some View {
        switch tool {
        case .convert:
            formatPicker
            Toggle("Include edits", isOn: $includeEdits)
            destinationPicker(defaultText: "Same folder as each photo")
        case .resize:
            Picker("New size", selection: $resizeByPercent) {
                Text("Longest side").tag(false)
                Text("Percent").tag(true)
            }
            .pickerStyle(.segmented)
            if resizeByPercent {
                TextField("Percent", value: $percent, format: .number)
            } else {
                TextField("Pixels", value: $longestSide, format: .number)
            }
            Toggle("Enlarge photos smaller than this", isOn: $allowEnlarging)
            Toggle("Include edits", isOn: $includeEdits)
            formatPicker
            destinationPicker(defaultText: "A “Resized” folder next to each photo")
        case .rename:
            Picker("Rename by", selection: $rule.mode) {
                ForEach(RenameRule.Mode.allCases) { Text($0.title).tag($0) }
            }
            switch rule.mode {
            case .pattern:
                TextField("Pattern", text: $rule.pattern)
                Text("Use \(RenameRule.tokens.joined(separator: " ")). Example: Beach-{date}-{number}")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Start numbers at \(rule.startNumber)", value: $rule.startNumber, in: 0...99999)
                Stepper("Number digits: \(rule.digits)", value: $rule.digits, in: 1...6)
            case .findReplace:
                TextField("Find", text: $rule.find)
                TextField("Replace with", text: $rule.replace)
                Toggle("Match capitals", isOn: $rule.caseSensitive)
            case .changeCase:
                Picker("Make names", selection: $rule.textCase) {
                    ForEach(RenameRule.TextCase.allCases) { Text($0.title).tag($0) }
                }
            }
            Toggle("Lowercase extensions (.JPG → .jpg)", isOn: $rule.lowercaseExtension)
        case .rotate:
            Picker("Turn", selection: $turns) {
                Text("Left").tag(-1)
                Text("Right").tag(1)
                Text("Upside down").tag(2)
            }
            .pickerStyle(.segmented)
            Text("Turning is an edit like any other: the photo files aren’t rewritten. Photos already show the way the camera held them.")
                .font(.caption).foregroundStyle(.secondary)
        case .move:
            Picker("Action", selection: $copy) {
                Text("Move").tag(false)
                Text("Copy").tag(true)
            }
            .pickerStyle(.segmented)
            destinationPicker(defaultText: nil)
            Toggle("Sort into folders by date taken", isOn: $useDateFolders)
            if useDateFolders {
                Picker("Folders", selection: $dateStyle) {
                    ForEach(DateFolderPattern.Style.allCases) { Text($0.example).tag($0) }
                }
                TextField("Event name (optional)", text: $eventName)
            }
        }
    }

    private var formatPicker: some View {
        Group {
            Picker("Format", selection: Binding(get: { sameFormat ? nil : format },
                                               set: { if let f = $0 { format = f; sameFormat = false } else { sameFormat = true } })) {
                if tool == .resize { Text("Same as original").tag(ExportFormat?.none) }
                ForEach(ImageExporter.availableFormats) { Text($0.displayName).tag(ExportFormat?.some($0)) }
            }
            if (sameFormat && tool == .resize) || format.isLossy {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $quality, in: 0.4...1).accessibilityLabel("Quality")
                        Text("\(Int((quality * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func destinationPicker(defaultText: String?) -> some View {
        LabeledContent("Save to") {
            HStack {
                Text(destination?.lastPathComponent ?? defaultText ?? "Choose a folder")
                    .foregroundStyle(destination == nil && defaultText == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if destination != nil, defaultText != nil {
                    Button("Reset") { destination = nil }
                }
                Button("Choose…") { chooseFolder() }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { destination = panel.url }
    }

    // MARK: Preview

    private struct Line: Identifiable {
        let id: Int
        let from: String
        let to: String
        let problem: String?
    }

    private var lines: [Line] {
        let shown = Array(photos.prefix(200))
        switch tool {
        case .rename:
            return preview.prefix(200).enumerated().map { i, item in
                Line(id: i, from: item.source.lastPathComponent, to: item.newName, problem: item.problem)
            }
        case .convert:
            return shown.enumerated().map { i, url in
                Line(id: i, from: url.lastPathComponent, to: ImageExporter.fileName(for: url, format: format), problem: nil)
            }
        case .resize:
            return shown.enumerated().map { i, url in
                let f = sameFormat ? BulkTools.sameFormat(as: url) : format
                let size = resizedSize(url)
                return Line(id: i, from: url.lastPathComponent,
                            to: "\(ImageExporter.fileName(for: url, format: f)) · \(size)", problem: nil)
            }
        case .rotate:
            return shown.enumerated().map { i, url in
                Line(id: i, from: url.lastPathComponent, to: turns == 2 ? "upside down" : turns < 0 ? "turned left" : "turned right",
                     problem: nil)
            }
        case .move:
            let pattern = useDateFolders ? DateFolderPattern(style: dateStyle, eventName: eventName) : nil
            let root = destination ?? URL(fileURLWithPath: "/Destination")
            return shown.enumerated().map { i, url in
                var path = url.lastPathComponent
                if let pattern {
                    let folder = pattern.folder(for: dates[url] ?? Date(), in: root)
                    path = folder.path.replacingOccurrences(of: root.path + "/", with: "").replacingOccurrences(of: "/", with: " › ")
                        + " › " + path
                }
                return Line(id: i, from: url.lastPathComponent, to: path, problem: nil)
            }
        }
    }

    private var previewList: some View {
        List(lines) { line in
            HStack(spacing: 8) {
                Text(line.from).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.to).lineLimit(1).truncationMode(.middle)
                    if let problem = line.problem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func resizedSize(_ url: URL) -> String {
        guard let info = try? ImageLoader.info(for: url) else { return "" }
        let current = Geometry.outputSize(of: (includeEdits ? model.recipe(for: url) : EditRecipe()).removing(.resize),
                                          source: info.pixelSize)
        let longest = Double(max(current.width, current.height))
        let target = resizeByPercent ? longest * percent / 100 : Double(longestSide)
        guard target < longest || allowEnlarging else { return "\(current.description) (unchanged)" }
        let s = target / longest
        return PixelSize(width: Int((Double(current.width) * s).rounded()),
                         height: Int((Double(current.height) * s).rounded())).description
    }

    private func refreshRenamePreview() {
        preview = RenamePlan.preview(rule, photos: photos, dates: dates)
    }

    // MARK: Running

    private var subtitle: String {
        let n = photos.count == 1 ? "1 photo" : "\(photos.count) photos"
        switch tool {
        case .convert: return "Saves \(n) as new files in another format. The originals are kept, and camera details carry over."
        case .resize: return "Saves smaller (or larger) copies of \(n). The originals are kept."
        case .rename: return "Renames \(n). Edits move with each photo."
        case .rotate: return "Turns \(n)."
        case .move: return copy ? "Copies \(n) to another folder, with their edits." : "Moves \(n) to another folder, with their edits."
        }
    }

    private var runTitle: String {
        switch tool {
        case .convert: "Convert"
        case .resize: "Resize"
        case .rename: "Rename \(preview.filter { $0.problem == nil && !$0.isUnchanged }.count)"
        case .rotate: "Rotate"
        case .move: copy ? "Copy" : "Move"
        }
    }

    private var canRun: Bool {
        guard !photos.isEmpty else { return false }
        switch tool {
        case .rename: return preview.contains { $0.problem == nil && !$0.isUnchanged }
        case .move: return destination != nil
        case .resize: return resizeByPercent ? percent > 0 : longestSide > 0
        default: return true
        }
    }

    private func run() {
        let options = ExportOptions(format: format, quality: quality)
        switch tool {
        case .convert:
            model.bulkConvert(photos, options: options, includeEdits: includeEdits, to: destination)
        case .resize:
            model.bulkResize(photos, rule: resizeByPercent ? .percent(percent) : .longestSide(longestSide),
                             allowEnlarging: allowEnlarging, format: sameFormat ? nil : format, quality: quality,
                             includeEdits: includeEdits, to: destination)
        case .rename:
            model.bulkRename(preview)
        case .rotate:
            model.bulkRotate(photos, turns: turns)
        case .move:
            guard let destination else { return }
            model.bulkTransfer(photos, copy: copy, to: destination,
                               dateFolders: useDateFolders ? DateFolderPattern(style: dateStyle, eventName: eventName) : nil,
                               dates: dates)
        }
        dismiss()
    }
}
