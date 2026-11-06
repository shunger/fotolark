import AppKit
import FotolarkKit
import SwiftUI
import UniformTypeIdentifiers

/// The grid of a folder's photos, with the Info panel for the selection.
struct BrowserView: View {
    @Bindable var model: AppModel
    @AppStorage("showInfo") private var showInfo = true

    var body: some View {
        HStack(spacing: 0) {
            grid
            if showInfo {
                Divider()
                InfoPanel(model: model, url: selectedSingle)
                    .frame(width: 260)
            }
        }
        .toolbar {
            if let progress = model.pasteProgress {
                ToolbarItem {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text("Pasting edits \(progress.done) of \(progress.total)")
                    }
                    .frame(width: 160)
                    .font(.caption)
                }
            }
            ToolbarItem {
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(PhotoSortOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort photos")
            }
            ToolbarItem {
                Slider(value: $model.thumbnailSize, in: 80...360)
                    .frame(width: 120)
                    .help("Thumbnail size")
                    .accessibilityLabel("Thumbnail size")
            }
            ToolbarItem {
                Button("Info", systemImage: "info.circle") { showInfo.toggle() }
                    .help("Show or hide photo details (⌘I)")
            }
        }
    }

    @ViewBuilder
    private var grid: some View {
        if model.photos.isEmpty {
            VStack(spacing: 10) {
                if model.isLoadingPhotos {
                    ProgressView()
                } else {
                    Image(systemName: "photo").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text("No photos in this folder").font(.title3)
                    Text("Photos in subfolders are listed under this folder in the sidebar.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PhotoGridView(photos: model.photos, recipes: model.recipes, selection: $model.selection,
                          thumbnailSize: model.thumbnailSize, thumbnails: model.thumbnails,
                          onOpen: { model.openEditor($0) },
                          makeMenu: { FileMenu.make(model: model) })
        }
    }

    private var selectedSingle: URL? {
        model.selection.count == 1 ? model.selection.first : nil
    }
}

/// The right-click menu for photos in the grid.
@MainActor
enum FileMenu {
    static func make(model: AppModel) -> NSMenu {
        let menu = NSMenu()
        let count = model.targetPhotos.count
        menu.addItem(ActionItem("Open", enabled: count == 1) { model.openSelection() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Copy Edits", enabled: model.editsToCopy != nil) { model.copyEdits() })
        menu.addItem(ActionItem(count == 1 ? "Paste Edits" : "Paste Edits onto \(count) Photos",
                                enabled: model.canPasteEdits) { model.pasteEdits() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show in Finder") { model.revealInFinder() })
        menu.addItem(ActionItem("Rename…", enabled: count == 1) { model.sheet = .rename })
        menu.addItem(ActionItem("Copy To…") { model.moveOrCopyTargets(copy: true) })
        menu.addItem(ActionItem("Move To…") { model.moveOrCopyTargets(copy: false) })
        menu.addItem(.separator())
        menu.addItem(ActionItem(count == 1 ? "Move to Trash" : "Move \(count) Photos to Trash") { model.moveTargetsToTrash() })
        return menu
    }
}

/// An NSMenuItem that runs a closure.
@MainActor
final class ActionItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() {
        handler()
    }
}

/// Thumbnails along the bottom of the editor for quick switching.
struct FilmstripView: View {
    @Bindable var model: AppModel
    let current: URL

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(model.photos) { photo in
                        FilmstripCell(photo: photo, recipe: model.recipes[photo.url], store: model.thumbnails,
                                      isCurrent: photo.url == current)
                            .id(photo.url)
                            .onTapGesture { model.openEditor(photo.url) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(current, anchor: .center) }
            .onChange(of: current) { withAnimation { proxy.scrollTo(current, anchor: .center) } }
        }
        .frame(height: 76)
        .background(.bar)
    }
}

private struct FilmstripCell: View {
    let photo: ScannedPhoto
    let recipe: EditRecipe?
    let store: ThumbnailStore
    let isCurrent: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            }
        }
        .frame(width: 64, height: 64)
        .padding(2)
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2.5)
        }
        .contentShape(Rectangle())
        .task(id: TaskKey(url: photo.url, modified: photo.modified, recipe: recipe)) {
            image = store.cachedThumbnail(for: photo, recipe: recipe, maxPixelSize: 160)
            if image == nil { image = await store.thumbnail(for: photo, recipe: recipe, maxPixelSize: 160) }
        }
        .accessibilityElement()
        .accessibilityLabel(photo.name)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    struct TaskKey: Equatable {
        let url: URL
        let modified: Date
        let recipe: EditRecipe?
    }
}

/// Camera, exposure, date, size and location of one photo.
struct InfoPanel: View {
    @Bindable var model: AppModel
    let url: URL?
    @State private var metadata: PhotoMetadata?
    @State private var fileSize: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Info").font(.headline).accessibilityAddTraits(.isHeader)
                if let url {
                    Text(url.lastPathComponent)
                        .font(.body.weight(.semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let m = metadata {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                            row("Taken", m.dateTaken?.formatted(date: .abbreviated, time: .shortened))
                            row("Camera", m.cameraName)
                            row("Lens", m.lens)
                            row("Exposure", m.exposureSummary)
                            row("Size", m.pixelSize.map { "\($0.description) px" })
                            row("Megapixels", m.pixelSize.map { String(format: "%.1f MP", Double($0.width * $0.height) / 1_000_000) })
                            row("File", fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                            row("Format", m.typeIdentifier.flatMap { UTType($0)?.localizedDescription })
                            row("Location", m.coordinatesText)
                            row("Altitude", m.altitude.map { "\(Int($0.rounded())) m" })
                            row("Folder", url.deletingLastPathComponent().path)
                        }
                        .font(.callout)
                        if model.recipes[url] != nil {
                            Label("Edited in Fotolark. The original file is unchanged.", systemImage: "slider.horizontal.3")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(model.selection.count > 1 ? "\(model.selection.count) photos selected" : "Select a photo to see its details.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: url) {
            metadata = nil
            guard let url else { return }
            let (m, size) = await Task.detached(priority: .userInitiated) {
                (PhotoMetadata.read(url), (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init))
            }.value
            metadata = m
            fileSize = size
        }
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value {
            GridRow {
                Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct RenameSheet: View {
    @Bindable var model: AppModel
    let url: URL
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename").font(.title2.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            Text("The extension (.\(url.pathExtension)) is kept if you leave it out. Edits move with the photo.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = url.deletingPathExtension().lastPathComponent }
    }

    private func commit() {
        dismiss()
        model.rename(url, to: name)
    }
}
