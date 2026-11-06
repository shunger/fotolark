import FotolarkKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("showFilmstrip") private var showFilmstrip = true
    @State private var isDropTargeted = false
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
        } detail: {
            detail
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .export: ExportSheet(model: model, photos: model.targetPhotos)
            case .resize: if let editor = model.editor { ResizeSheet(editor: editor) }
            case .rename: if let url = model.targetPhotos.first { RenameSheet(model: model, url: url) }
            case .bulk(let tool): BulkSheet(model: model, photos: model.targetPhotos, tool: tool)
            case .newAlbum(let photos): AlbumNameSheet(model: model, photos: photos)
            case .renameAlbum(let id): AlbumNameSheet(model: model, renaming: id)
            case .pages(let mode, let photos): PageSheet(model: model, photos: photos, mode: mode)
            case .collage(let photos): CollageSheet(model: model, photos: photos)
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let editor = model.editor {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    CanvasView(editor: editor, model: model)
                    if showFilmstrip && model.photos.count > 1 {
                        Divider()
                        FilmstripView(model: model, current: editor.url)
                    }
                }
                if showInspector {
                    Divider()
                    EditorSidePanel(editor: editor, model: model)
                        .frame(width: 290)
                }
            }
            .toolbar { EditorToolbar(editor: editor, model: model, showInspector: $showInspector) }
            .alert("Save over the original?", isPresented: $model.isConfirmingOverwrite) {
                Button("Save Over Original", role: .destructive) { model.saveOverOriginal() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("“\(editor.url.lastPathComponent)” will be replaced with the edited version. A backup of the original is kept and can be found with File › Show Backups in Finder.")
            }
        } else if let photos = model.comparing {
            CompareView(model: model, photos: photos)
        } else if case .importing(let key) = model.source {
            if let source = model.importSource(for: key) {
                ImportView(model: model, source: source).id(key)
                    .toolbar { ToolbarItem { JobsButton(model: model) } }
            } else {
                Text("This device was disconnected.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.source != nil {
            BrowserView(model: model)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button("Open", systemImage: "plus") { model.showOpenPanel() }
                            .help("Open photos or add a folder (⌘O)")
                    }
                }
        } else {
            EmptyStateView(model: model, isDropTargeted: isDropTargeted)
        }
    }

    private var title: String {
        if let editor = model.editor { return editor.url.lastPathComponent }
        switch model.source {
        case .folder(let url): return url.lastPathComponent
        case .opened: return "Opened Photos"
        case .album: return model.currentAlbum?.name ?? "Album"
        case .timeline: return "All Photos"
        case .search(let text): return "Search: \(text)"
        case .importing(let key): return model.importSource(for: key)?.title ?? "Import"
        case nil: return "Fotolark"
        }
    }

    private var subtitle: String {
        if let editor = model.editor {
            return [model.positionText, "\(editor.editedSize.description) px"].compactMap { $0 }.joined(separator: " · ")
        }
        guard let source = model.source, source.isBrowsable else { return "" }
        let n = model.photos.count
        let selected = model.selection.count > 1 ? " · \(model.selection.count) selected" : ""
        return (n == 1 ? "1 photo" : "\(n) photos") + selected
    }
}

/// The editor's right-hand panel: editing controls, or the photo's details.
struct EditorSidePanel: View {
    @Bindable var editor: PhotoEditor
    @Bindable var model: AppModel
    @AppStorage("editorPanel") private var panel = "edit"

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $panel) {
                Text("Edit").tag("edit")
                Text("Info").tag("info")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 12)
            .disabled(editor.tool != .none)
            if panel == "info" && editor.tool == .none {
                InfoPanel(model: model, url: editor.url)
            } else {
                InspectorView(editor: editor, model: model)
            }
        }
    }
}

struct EditorToolbar: ToolbarContent {
    @Bindable var editor: PhotoEditor
    @Bindable var model: AppModel
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("All Photos", systemImage: "square.grid.2x2") { model.closeEditor() }
                .help("Back to all photos (Esc)")
            Button("Previous", systemImage: "chevron.left") { model.previous() }
                .disabled(!model.canGoPrevious)
                .help("Previous photo (←)")
            Button("Next", systemImage: "chevron.right") { model.next() }
                .disabled(!model.canGoNext)
                .help("Next photo (→)")
        }
        ToolbarItemGroup {
            Button("Open", systemImage: "folder") { model.showOpenPanel() }
                .help("Open photos or a folder (⌘O)")
            Button("Rotate Left", systemImage: "rotate.left") { editor.rotate(clockwise: false) }
                .help("Rotate left (⌘[)")
            Button("Rotate Right", systemImage: "rotate.right") { editor.rotate(clockwise: true) }
                .help("Rotate right (⌘])")
            CompareButton(editor: editor)
            Button("Slideshow", systemImage: "play.rectangle") { model.startSlideshow() }
                .help("Play the photos full screen from this one (⌥⌘P)")
            Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                .disabled(!editor.history.canUndo)
                .help("Undo (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { editor.redo() }
                .disabled(!editor.history.canRedo)
                .help("Redo (⇧⌘Z)")
            Button("Export", systemImage: "arrow.down.doc") { model.sheet = .export }
                .help("Export an edited copy (⌘E)")
            ShareButton(model: model)
            JobsButton(model: model)
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                .help("Show or hide the editing panel (⌥⌘I)")
        }
    }
}

/// Press and hold to see the original photo.
struct CompareButton: View {
    @Bindable var editor: PhotoEditor

    var body: some View {
        Image(systemName: editor.showOriginal ? "eye.fill" : "eye")
            .frame(width: 28, height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in editor.showOriginal = true }
                    .onEnded { _ in editor.showOriginal = false }
            )
            .help("Hold to see the original (or hold the \\ key)")
            .accessibilityLabel("Show original")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { editor.showOriginal.toggle() }
    }
}

struct EmptyStateView: View {
    @Bindable var model: AppModel
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop photos or a folder here")
                .font(.title2.weight(.semibold))
            Text("Fotolark edits photos where they are. Your originals are never changed unless you choose Save Over Original.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380)
            Button("Open Photos…") { model.showOpenPanel() }
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(24)
        }
    }
}
