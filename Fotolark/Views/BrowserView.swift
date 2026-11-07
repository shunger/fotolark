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
            VStack(spacing: 0) {
                if model.filter.isActive {
                    FilterBar(model: model)
                    Divider()
                }
                grid
            }
            if showInfo {
                Divider()
                InfoPanel(model: model, url: selectedSingle)
                    .frame(width: 260)
            }
        }
        .toolbar(id: "browser") {
            // Right-click the toolbar › Customize Toolbar… to change what's here.
            ToolbarItem(id: "open", placement: .navigation) {
                Button("Open", systemImage: "plus") { model.showOpenPanel() }
                    .help("Open photos or add a folder (⌘O)")
            }
            ToolbarItem(id: "filter") { FilterMenu(model: model) }
            ToolbarItem(id: "sort") {
                Picker("Sort", selection: $model.sortOrder) {
                    ForEach(PhotoSortOrder.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(!(model.source?.isFolderLike ?? true))
                .help(model.source?.isFolderLike ?? true ? "Sort photos" : "Newest first")
            }
            ToolbarItem(id: "size") {
                Slider(value: $model.thumbnailSize, in: 80...360)
                    .frame(width: 120)
                    .help("Thumbnail size")
                    .accessibilityLabel("Thumbnail size")
            }
            ToolbarItem(id: "bulk") {
                Menu {
                    ForEach(BulkTool.allCases) { tool in
                        Button { model.sheet = .bulk(tool) } label: { Label("\(tool.title)…", systemImage: tool.systemImage) }
                    }
                } label: {
                    Label("Bulk", systemImage: "square.stack.3d.up")
                }
                .disabled(model.targetPhotos.isEmpty)
                .help("Convert, resize, rename, rotate or move the selected photos")
            }
            ToolbarItem(id: "export") {
                Button("Export", systemImage: "arrow.down.doc") { model.sheet = .export }
                    .disabled(model.targetPhotos.isEmpty)
                    .help("Export edited copies (⌘E)")
            }
            ToolbarItem(id: "share") { ShareButton(model: model) }
            ToolbarItem(id: "jobs") { JobsButton(model: model) }
            ToolbarItem(id: "more") { BrowserMoreMenu(model: model) }
            ToolbarItem(id: "info") {
                Button("Info", systemImage: "info.circle") { showInfo.toggle() }
                    .help("Show or hide photo details (⌘I)")
            }
            // Off by default; in the More menu, or add them with Customize Toolbar.
            ToolbarItem(id: "slideshow", showsByDefault: false) {
                Button("Slideshow", systemImage: "play.rectangle") { model.startSlideshow() }
                    .disabled(!model.canStartSlideshow)
                    .help("Play the photos full screen (⌥⌘P). Plays just the selected ones if several are selected.")
            }
            ToolbarItem(id: "compare", showsByDefault: false) {
                Button("Compare", systemImage: "rectangle.split.2x1") { model.compareSelection() }
                    .disabled(!model.canCompare)
                    .help("Compare 2 to 4 selected photos side by side (⌥⌘K)")
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
                    if model.filter.isActive && model.loadedCount > 0 {
                        Text("No photos match the filter").font(.title3)
                        Button("Clear Filter") { model.filter = GridFilter() }
                    } else if case .search(let text) = model.source {
                        Text("Nothing found for “\(text)”").font(.title3)
                        Text("Search looks at names, folders, tags, cameras, dates (try “July 2024”) and text in photos.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                        if let status = model.indexStatus { Text(status).font(.callout).foregroundStyle(.secondary) }
                    } else if model.source == .timeline {
                        Text(model.library.roots.isEmpty ? "Add a folder to see your photos here" : "Looking for photos…")
                            .font(.title3)
                    } else if model.currentFaceGroup == nil, model.source.map({ if case .person = $0 { true } else { false } }) ?? false {
                        Text("Still looking for this person’s photos…").font(.title3)
                    } else if model.currentAlbum != nil {
                        Text("No photos in this album").font(.title3)
                        Text("Select photos in a folder, then right-click and choose Add to Album.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No photos in this folder").font(.title3)
                        Text("Photos in subfolders are listed under this folder in the sidebar.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PhotoGridView(photos: model.photos, recipes: model.recipes, labels: model.labels,
                          sections: model.sections,
                          selection: $model.selection,
                          thumbnailSize: model.thumbnailSize, thumbnails: model.thumbnails,
                          promises: model.promises,
                          onOpen: { model.openEditor($0) },
                          makeMenu: { FileMenu.make(model: model) },
                          onLabel: { model.applyLabel($0) })
        }
    }

    private var selectedSingle: URL? {
        model.selection.count == 1 ? model.selection.first : nil
    }
}

/// Less-used grid actions, out of the way.
struct BrowserMoreMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Button("Slideshow", systemImage: "play.rectangle") { model.startSlideshow() }
                .disabled(!model.canStartSlideshow)
            Button("Compare Selected", systemImage: "rectangle.split.2x1") { model.compareSelection() }
                .disabled(!model.canCompare)
            Divider()
            Button("Print…", systemImage: "printer") { model.showPages(.print) }
                .disabled(model.layoutPhotos.isEmpty)
            Button("Make Collage…", systemImage: "rectangle.3.group") { model.showCollage() }
                .disabled(model.layoutPhotos.count < 2)
            Button("Make Contact Sheet…", systemImage: "square.grid.3x3") { model.showPages(.contactSheet) }
                .disabled(model.layoutPhotos.isEmpty)
            Button("Export as PDF…", systemImage: "doc.richtext") { model.showPages(.pdf) }
                .disabled(model.layoutPhotos.isEmpty)
            Divider()
            Button("Find Duplicates…", systemImage: "square.on.square") { model.showDuplicates() }
                .disabled(model.photos.count < 2)
            Button("Show in Finder", systemImage: "folder") { model.revealInFinder() }
                .disabled(model.targetPhotos.isEmpty)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .help("More: slideshow, compare, print, collage, duplicates")
    }
}

/// Show only photos with enough stars, a flag or a tag.
struct FilterMenu: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Picker("Stars", selection: $model.filter.minRating) {
                Text("Any Rating").tag(0)
                ForEach(1...5, id: \.self) { r in
                    Text(String(repeating: "★", count: r) + (r < 5 ? " or More" : "")).tag(r)
                }
            }
            Picker("Flag", selection: $model.filter.flag) {
                ForEach(GridFilter.FlagFilter.allCases) { Text($0.title).tag($0) }
            }
            Picker("Tag", selection: $model.filter.tag) {
                Text("Any Tag").tag(String?.none)
                ForEach(model.knownTags, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Divider()
            Button("Clear Filter") { model.filter = GridFilter() }
                .disabled(!model.filter.isActive)
        } label: {
            Label("Filter", systemImage: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill"
                                                             : "line.3.horizontal.decrease.circle")
        }
        .help("Show only some photos: by stars, pick or reject, or tag")
    }
}

/// Says a filter is hiding photos, with a way to clear it.
struct FilterBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").foregroundStyle(Color.accentColor)
            Text("Showing \(model.photos.count.formatted()) of \(model.loadedCount.formatted()): \(model.filter.summary)")
                .lineLimit(1)
            Spacer()
            Button("Clear Filter") { model.filter = GridFilter() }
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// The right-click menu for photos in the grid.
@MainActor
enum FileMenu {
    static func make(model: AppModel) -> NSMenu {
        let menu = NSMenu()
        let count = model.targetPhotos.count
        menu.addItem(ActionItem("Open", enabled: count == 1) { model.openSelection() })
        menu.addItem(ActionItem("Compare", enabled: model.canCompare) { model.compareSelection() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Copy Edits", enabled: model.editsToCopy != nil) { model.copyEdits() })
        menu.addItem(ActionItem(count == 1 ? "Revert to Original" : "Revert \(count) Photos to Original",
                                enabled: model.targetPhotos.contains { model.recipes[$0] != nil }) {
            model.revertTargetsToOriginal()
        })
        menu.addItem(ActionItem(count == 1 ? "Paste Edits" : "Paste Edits onto \(count) Photos",
                                enabled: model.canPasteEdits) { model.pasteEdits() })
        menu.addItem(.separator())
        menu.addItem(ratingMenu(model: model))
        menu.addItem(albumMenu(model: model))
        if model.currentAlbum != nil {
            menu.addItem(ActionItem(count == 1 ? "Remove from Album" : "Remove \(count) Photos from Album") {
                model.removeFromCurrentAlbum()
            })
        }
        if model.currentFaceGroup != nil {
            menu.addItem(ActionItem("Not This Person") { model.removeFromFaceGroup() })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show in Finder") { model.revealInFinder() })
        menu.addItem(ActionItem("Rename…", enabled: count == 1) { model.sheet = .rename })
        let bulk = NSMenuItem(title: "Bulk", action: nil, keyEquivalent: "")
        bulk.submenu = NSMenu()
        for tool in BulkTool.allCases {
            bulk.submenu?.addItem(ActionItem("\(tool.title)…") { model.sheet = .bulk(tool) })
        }
        menu.addItem(bulk)
        menu.addItem(ActionItem("Print…") { model.showPages(.print) })
        menu.addItem(ActionItem("Make Collage…", enabled: count > 1) { model.showCollage() })
        menu.addItem(ActionItem(count == 1 ? "Remove Background…" : "Remove Background from \(count) Photos…") {
            model.removeBackground()
        })
        menu.addItem(ActionItem("Copy To…") { model.moveOrCopyTargets(copy: true) })
        menu.addItem(ActionItem("Move To…") { model.moveOrCopyTargets(copy: false) })
        menu.addItem(.separator())
        menu.addItem(ActionItem(count == 1 ? "Move to Trash" : "Move \(count) Photos to Trash") { model.moveTargetsToTrash() })
        return menu
    }

    static func ratingMenu(model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: "Rating and Flag", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for r in 0...5 {
            let title = r == 0 ? "No Stars" : String(repeating: "★", count: r)
            let entry = ActionItem(title) { model.applyLabel(.rating(r)) }
            entry.keyEquivalent = "\(r)"
            entry.keyEquivalentModifierMask = []
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        for (title, flag, key) in [("Pick", PhotoLabels.Flag.pick, "p"), ("Reject", .reject, "x"), ("Clear Flag", .none, "u")] {
            let entry = ActionItem(title) { model.applyLabel(.flag(flag)) }
            entry.keyEquivalent = key
            entry.keyEquivalentModifierMask = []
            sub.addItem(entry)
        }
        item.submenu = sub
        return item
    }

    static func albumMenu(model: AppModel) -> NSMenuItem {
        let item = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let targets = model.targetPhotos
        for album in model.albums where album.id != model.currentAlbum?.id {
            let inAll = targets.allSatisfy { album.contains($0) }
            let entry = ActionItem(album.name, enabled: !inAll) { model.addToAlbum(album.id, photos: targets) }
            if inAll { entry.state = .on }
            sub.addItem(entry)
        }
        if !model.albums.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ActionItem("New Album…") { model.sheet = .newAlbum(targets) })
        item.submenu = sub
        return item
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
    @Environment(\.colorScheme) private var outsideScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            .onChange(of: current) {
                if reduceMotion {
                    proxy.scrollTo(current, anchor: .center)
                } else {
                    withAnimation { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
        .frame(height: 76)
        .background(PhotoBackdrop())
        .environment(\.colorScheme, PhotoBackground.current == .system ? outsideScheme : .dark)
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
                if !labelTargets.isEmpty {
                    LabelsEditor(model: model, urls: labelTargets)
                    Divider()
                }
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
                            row("Keywords", m.keywords.isEmpty ? nil : m.keywords.joined(separator: ", "))
                            row("Albums", albumNames(url))
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

    /// The photo shown, or every selected photo.
    private var labelTargets: [URL] {
        if let url { return [url] }
        return model.selection.count > 1 ? model.targetPhotos : []
    }

    private func albumNames(_ url: URL) -> String? {
        let names = model.albums.filter { $0.contains(url) }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
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
