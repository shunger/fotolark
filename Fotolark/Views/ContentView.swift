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
            case .duplicates(let photos): DuplicatesSheet(model: model, photos: photos)
            case .welcome: WelcomeTour(model: model)
            }
        }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeView(model: model, notice: notice)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(notice.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.notice)
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
                        // Nothing in the panel may spill over the photo.
                        .clipped()
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
        } else if model.source == .people {
            PeopleView(model: model)
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
        case .people: return "People"
        case .person, .faceGroup: return model.currentFaceGroup?.person?.name ?? "Unnamed person"
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
            Toggle(isOn: $editor.splitCompare) {
                Label("Before and After", systemImage: "rectangle.split.2x1")
            }
            .help("Show before and after side by side; drag the divider (Y)")
            Button("Slideshow", systemImage: "play.rectangle") { model.startSlideshow() }
                .help("Play the photos full screen from this one (⌥⌘P)")
            Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                .disabled(!editor.history.canUndo)
                .help("Undo (⌘Z)")
            Button("Redo", systemImage: "arrow.uturn.forward") { editor.redo() }
                .disabled(!editor.history.canRedo)
                .help("Redo (⇧⌘Z)")
            if model.isEditingPhotosPicture {
                Button("Save to Photos", systemImage: "photo.badge.checkmark") { model.saveToPhotos() }
                    .disabled(model.isSavingToPhotos)
                    .help("Save this edit back into Apple Photos (Photos keeps the original)")
            }
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

/// "Done: Import 3,365 from iPhone" with Show and Details; fades away on its own
/// unless the pointer is over it.
struct NoticeView: View {
    @Bindable var model: AppModel
    let notice: AppModel.Notice
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: notice.hasProblems ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.hasProblems ? Color.orange : Color.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.text).lineLimit(1).truncationMode(.middle)
                if let detail = notice.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let folder = notice.folder {
                Button("Show") { model.showFolder(folder); model.notice = nil }
            }
            if notice.hasProblems {
                Button("Details") { model.jobs.showListRequests += 1; model.notice = nil }
            }
            Button { model.notice = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .onHover { hovering = $0 }
        .task(id: notice.id) {
            // Linger a little longer when something needs a look.
            let seconds = notice.hasProblems ? 12.0 : 7.0
            var waited = 0.0
            while waited < seconds {
                try? await Task.sleep(for: .milliseconds(250))
                if !hovering { waited += 0.25 }
            }
            if model.notice?.id == notice.id { model.notice = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(notice.text)
    }
}
