import AppKit
import FotolarkKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Print, contact sheet and PDF export: page options with a preview of the first page.
struct PageSheet: View {
    enum Mode: String {
        case print, contactSheet, pdf

        var title: String {
            switch self {
            case .print: "Print"
            case .contactSheet: "Contact Sheet"
            case .pdf: "Export as PDF"
            }
        }
    }

    @Bindable var model: AppModel
    let photos: [URL]
    let mode: Mode
    @State private var settings: PageSettings
    @State private var preview: NSImage?
    @State private var pageCount = 0
    @State private var working: String?
    @State private var cancelled = false
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, photos: [URL], mode: Mode) {
        self.model = model
        self.photos = photos
        self.mode = mode
        var s = UserDefaults.standard.data(forKey: "pages.\(mode.rawValue)")
            .flatMap { try? JSONDecoder().decode(PageSettings.self, from: $0) } ?? PageSettings()
        if mode == .pdf && UserDefaults.standard.data(forKey: "pages.pdf") == nil { s.margin = 0.5 }
        _settings = State(initialValue: s)
    }

    private var kind: PDFComposer.Kind {
        mode == .contactSheet ? .contactSheet(title: model.sourceTitle) : .prints
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                previewPane
                options.frame(width: 280)
            }
            .padding(20)
            Divider()
            HStack {
                if let working {
                    ProgressView().controlSize(.small)
                    Text(working).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(photos.count) \(photos.count == 1 ? "photo" : "photos") · \(pageCount) \(pageCount == 1 ? "page" : "pages")")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { cancelled = true; dismiss() }
                    .keyboardShortcut(.cancelAction)
                if mode == .pdf {
                    Button("Save PDF…") { savePDF() }.keyboardShortcut(.defaultAction).disabled(working != nil)
                } else {
                    Button("Save as PDF…") { savePDF() }.disabled(working != nil)
                    Button("Print…") { printPages() }.keyboardShortcut(.defaultAction).disabled(working != nil)
                }
            }
            .padding(16)
        }
        .frame(width: 760)
        .task(id: settings) {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "pages.\(mode.rawValue)")
            try? await Task.sleep(for: .milliseconds(200))
            await makePreview()
        }
    }

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .padding(16)
            } else {
                ProgressView()
            }
        }
        .frame(width: 420, height: 460)
        .accessibilityLabel("Preview of the first page")
    }

    @ViewBuilder
    private var options: some View {
        Form {
            Text(mode.title).font(.title2.weight(.semibold))
            Picker("Paper", selection: $settings.paper) {
                ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
            }
            Picker("Orientation", selection: $settings.landscape) {
                Text("Portrait").tag(false)
                Text("Landscape").tag(true)
            }
            .pickerStyle(.segmented)
            if mode == .contactSheet {
                Stepper("Photos per row: \(settings.columns)", value: $settings.columns, in: 2...12)
                Toggle("Show file names", isOn: $settings.showNames)
            } else {
                Picker("Photo size", selection: $settings.printSize) {
                    ForEach(PrintSize.allCases) { Text($0.title).tag($0) }
                }
                Picker("Fit", selection: $settings.fill) {
                    Text("Whole photo").tag(false)
                    Text("Fill (crop edges)").tag(true)
                }
                .pickerStyle(.radioGroup)
                Toggle("Turn photos to print bigger", isOn: $settings.autoRotate)
                if PageLayout.printCells(settings).count > 1 {
                    Toggle("Fill each page with copies of one photo", isOn: $settings.repeatEach)
                }
            }
            Picker("Margins", selection: $settings.margin) {
                Text("None").tag(0.0)
                Text("Narrow (¼ in)").tag(0.25)
                Text("Normal (½ in)").tag(0.5)
            }
        }
        .formStyle(.columns)
    }

    private func items() -> [PageItem] {
        photos.map { PageItem(url: $0, recipe: model.recipe(for: $0)) }
    }

    private func makePreview() async {
        let items = items(), settings = settings, kind = kind, engine = model.engine
        pageCount = PDFComposer.pages(count: items.count, kind: kind, settings: settings).count
        let data = await Task.detached(priority: .userInitiated) {
            try? PDFComposer.make(items, kind: kind, settings: settings, engine: engine, dpi: 60, pageLimit: 1)
        }.value
        guard !Task.isCancelled, let data, let page = PDFDocument(data: data)?.page(at: 0) else { return }
        preview = page.thumbnail(of: NSSize(width: 800, height: 900), for: .mediaBox)
    }

    /// The full-quality PDF, made in the background with progress.
    private func fullPDF() async -> Data? {
        let items = items(), settings = settings, kind = kind, engine = model.engine
        working = "Preparing pages…"
        defer { working = nil }
        let cancelFlag = CancelFlag()
        let progressBox = ProgressBox()
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                if let p = progressBox.value { working = "Preparing page \(min(p.0 + 1, p.1)) of \(p.1)…" }
                if cancelled { cancelFlag.set() }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poll.cancel() }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try PDFComposer.make(items, kind: kind, settings: settings, engine: engine,
                                     progress: { done, total in progressBox.value = (done, total) },
                                     isCancelled: { cancelFlag.isSet })
            }.value
        } catch {
            model.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func savePDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (mode == .contactSheet ? "\(model.sourceTitle) contact sheet" : model.sourceTitle) + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let data = await fullPDF() else { return }
            do {
                try data.write(to: url, options: .atomic)
                dismiss()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func printPages() {
        Task {
            guard let data = await fullPDF(), let doc = PDFDocument(data: data) else { return }
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.paperSize = settings.paper.points
            info.orientation = settings.landscape ? .landscape : .portrait
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = true
            guard let op = doc.printOperation(for: info, scalingMode: .pageScaleNone, autoRotate: true) else { return }
            op.jobTitle = "\(model.sourceTitle) – Fotolark"
            dismiss()
            op.run()
        }
    }
}

/// Thread-safe flags for the background PDF job.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var isSet: Bool { lock.withLock { flag } }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: (Int, Int)?
    var value: (Int, Int)? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Arrange photos on one picture and save it.
struct CollageSheet: View {
    @Bindable var model: AppModel
    let photos: [URL]
    @State private var settings: CollageSettings = UserDefaults.standard.data(forKey: "collage.settings")
        .flatMap { try? JSONDecoder().decode(CollageSettings.self, from: $0) } ?? CollageSettings()
    @State private var preview: CGImage?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().scaledToFit().padding(12)
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 460, height: 400)
                .accessibilityLabel("Collage preview")

                Form {
                    Text("Collage").font(.title2.weight(.semibold))
                    Picker("Layout", selection: $settings.layout) {
                        ForEach(CollageSettings.Layout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    if settings.layout == .freeform {
                        Button("Shuffle") { settings.seed &+= 1 }
                    }
                    Picker("Size", selection: $settings.size) {
                        ForEach(CollageSettings.sizes, id: \.size) { Text($0.title).tag($0.size) }
                    }
                    if settings.layout != .freeform {
                        Slider(value: $settings.spacing, in: 0...0.05) { Text("Spacing") }
                    }
                    ColorPicker("Background", selection: Binding(get: {
                        Color(.sRGB, red: settings.background.red, green: settings.background.green, blue: settings.background.blue)
                    }, set: { color in
                        guard let ns = NSColor(color).usingColorSpace(.sRGB) else { return }
                        settings.background = RGBAColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
                    }), supportsOpacity: false)
                    Text(photos.count > 30 ? "That's a lot of photos for one collage; each will be small." :
                            "Photos are filled into their spaces, so their edges may be trimmed a little.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .formStyle(.columns)
                .frame(width: 260)
            }
            .padding(20)
            Divider()
            HStack {
                if saving { ProgressView().controlSize(.small); Text("Saving…").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Collage…") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
            }
            .padding(16)
        }
        .frame(width: 780)
        .task(id: settings) {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "collage.settings")
            try? await Task.sleep(for: .milliseconds(150))
            var small = settings
            let scale = 700 / Double(max(settings.size.width, settings.size.height))
            small.size = PixelSize(width: Int(Double(settings.size.width) * scale), height: Int(Double(settings.size.height) * scale))
            let items = photos.map { PageItem(url: $0, recipe: model.recipe(for: $0)) }
            let engine = model.engine
            let image = await Task.detached(priority: .userInitiated) {
                CollageMaker.render(items, settings: small, engine: engine).flatMap { engine.makeCGImage($0) }
            }.value
            if !Task.isCancelled { preview = image }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = "\(model.sourceTitle) collage.jpg"
        if let folder = photos.first?.deletingLastPathComponent() { panel.directoryURL = folder }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = photos.map { PageItem(url: $0, recipe: model.recipe(for: $0)) }
        let settings = settings, engine = model.engine
        saving = true
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    guard let image = CollageMaker.render(items, settings: settings, engine: engine),
                          let cg = engine.makeCGImage(image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
                        throw FotolarkError.cannotEncode("collage")
                    }
                    let type = url.pathExtension.lowercased() == "png" ? UTType.png : UTType.jpeg
                    let data = NSMutableData()
                    guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                        throw FotolarkError.cannotEncode(type.identifier)
                    }
                    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
                    guard CGImageDestinationFinalize(dest) else { throw FotolarkError.cannotEncode(type.identifier) }
                    try (data as Data).write(to: url, options: .atomic)
                }.value
                saving = false
                dismiss()
            } catch {
                saving = false
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
