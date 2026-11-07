import FotolarkKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("showFilmstrip") private var showFilmstrip = true
    @State private var isDropTargeted = false
    @State private var columns = NavigationSplitViewVisibility.all
    /// The sidebar as it was before a photo opened, to put back afterwards.
    @State private var columnsBeforeEditing: NavigationSplitViewVisibility?
    @AppStorage("hideSidebarWhileEditing") private var hideSidebarWhileEditing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
        } detail: {
            detail
                // A short crossfade between the grid and the editor.
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.editor?.url)
        }
        // More room for the photo: the sidebar steps aside while editing.
        .onChange(of: model.editor != nil) { _, editing in
            guard hideSidebarWhileEditing else { return }
            if editing {
                columnsBeforeEditing = columns
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { columns = .detailOnly }
            } else if let before = columnsBeforeEditing {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { columns = before }
                columnsBeforeEditing = nil
            }
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
                    // Out of the way while zoomed in.
                    if showFilmstrip && model.photos.count > 1 && model.zoomScale == nil {
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
            .toolbar(id: "editor") { EditorToolbar(editor: editor, model: model, showInspector: $showInspector) }
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

/// The editor's toolbar. Right-click it › Customize Toolbar… to add or remove buttons;
/// less-used ones start hidden and are also in the More menu.
struct EditorToolbar: CustomizableToolbarContent {
    @Bindable var editor: PhotoEditor
    @Bindable var model: AppModel
    @Binding var showInspector: Bool

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "back", placement: .navigation) {
            Button("All Photos", systemImage: "square.grid.2x2") { model.closeEditor() }
                .help("Back to all photos (Esc)")
        }
        ToolbarItem(id: "previous", placement: .navigation) {
            Button("Previous", systemImage: "chevron.left") { model.previous() }
                .disabled(!model.canGoPrevious)
                .help("Previous photo (←)")
        }
        ToolbarItem(id: "next", placement: .navigation) {
            Button("Next", systemImage: "chevron.right") { model.next() }
                .disabled(!model.canGoNext)
                .help("Next photo (→)")
        }
        ToolbarItem(id: "undo") {
            Button("Undo", systemImage: "arrow.uturn.backward") { editor.undo() }
                .disabled(!editor.history.canUndo)
                .help("Undo (⌘Z)")
        }
        ToolbarItem(id: "redo") {
            Button("Redo", systemImage: "arrow.uturn.forward") { editor.redo() }
                .disabled(!editor.history.canRedo)
                .help("Redo (⇧⌘Z)")
        }
        ToolbarItem(id: "split") {
            Toggle(isOn: $editor.splitCompare) {
                Label("Before and After", systemImage: "rectangle.split.2x1")
            }
            .help("Show before and after side by side; drag the divider (Y)")
        }
        ToolbarItem(id: "save-to-photos") {
            if model.isEditingPhotosPicture {
                Button("Save to Photos", systemImage: "photo.badge.checkmark") { model.saveToPhotos() }
                    .disabled(model.isSavingToPhotos)
                    .help("Save this edit back into Apple Photos (Photos keeps the original)")
            }
        }
        ToolbarItem(id: "export") {
            Button("Export", systemImage: "arrow.down.doc") { model.sheet = .export }
                .help("Export an edited copy (⌘E)")
        }
        ToolbarItem(id: "share") { ShareButton(model: model) }
        ToolbarItem(id: "jobs") { JobsButton(model: model) }
        ToolbarItem(id: "more") {
            Menu {
                Button("Rotate Left", systemImage: "rotate.left") { editor.rotate(clockwise: false) }
                Button("Rotate Right", systemImage: "rotate.right") { editor.rotate(clockwise: true) }
                Button("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                    editor.flip(horizontally: true)
                }
                Button("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                    editor.flip(horizontally: false)
                }
                Divider()
                Button("Slideshow from Here", systemImage: "play.rectangle") { model.startSlideshow() }
                Button("Print…", systemImage: "printer") { model.showPages(.print) }
                Button("Show in Finder", systemImage: "folder") { model.revealInFinder() }
                Button("Open Photos…", systemImage: "plus") { model.showOpenPanel() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .help("More: rotate, flip, slideshow, print")
        }
        ToolbarItem(id: "inspector") {
            Button("Editing Panel", systemImage: "sidebar.right") { showInspector.toggle() }
                .help("Show or hide the editing panel (⌥⌘I)")
        }
        // Off by default; add them with Customize Toolbar.
        ToolbarItem(id: "rotate-left", showsByDefault: false) {
            Button("Rotate Left", systemImage: "rotate.left") { editor.rotate(clockwise: false) }
                .help("Rotate left (⌘[)")
        }
        ToolbarItem(id: "rotate-right", showsByDefault: false) {
            Button("Rotate Right", systemImage: "rotate.right") { editor.rotate(clockwise: true) }
                .help("Rotate right (⌘])")
        }
        ToolbarItem(id: "hold-original", showsByDefault: false) { CompareButton(editor: editor) }
        ToolbarItem(id: "slideshow", showsByDefault: false) {
            Button("Slideshow", systemImage: "play.rectangle") { model.startSlideshow() }
                .help("Play the photos full screen from this one (⌥⌘P)")
        }
        ToolbarItem(id: "open", showsByDefault: false) {
            Button("Open", systemImage: "folder") { model.showOpenPanel() }
                .help("Open photos or a folder (⌘O)")
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
        VStack(spacing: 22) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text(model.library.roots.isEmpty ? "Let’s find your photos" : "Choose a folder in the sidebar")
                    .font(.title2.weight(.semibold))
                Text("Fotolark shows the photos where they already are and edits them without changing the originals.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            VStack(spacing: 10) {
                StartButton(title: "Add Your Pictures Folder…", detail: "Or any folder of photos on this Mac or a drive",
                            symbol: "folder.badge.plus") { addPicturesFolder() }
                StartButton(title: "Import from iPhone or Camera",
                            detail: model.devices.devices.isEmpty
                                ? "Connect it with a cable and unlock it first"
                                : "Copy photos from \(model.devices.devices[0].title)",
                            symbol: "iphone") {
                    if let device = model.devices.devices.first {
                        model.source = .importing(AppModel.importKey(device))
                    }
                }
                .disabled(model.devices.devices.isEmpty)
                StartButton(title: "Import from Apple Photos", detail: "Copy albums or photos out of your Photos library",
                            symbol: "photo.on.rectangle") { model.showPhotosLibrary() }
            }
            .frame(width: 380)
            Text("You can also drop photos or a folder anywhere in this window.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25))
                .padding(24)
        }
    }

    /// The folder picker, opened at the person's own Pictures folder.
    private func addPicturesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders of photos. Fotolark shows them in the sidebar and keeps them up to date."
        // The sandbox's home is the app's container; the real one comes from the account.
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            panel.directoryURL = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Pictures", isDirectory: true)
        }
        if panel.runModal() == .OK { model.open(panel.urls) }
    }
}

/// A large choice on the empty screen: a symbol, a title and a line under it.
private struct StartButton: View {
    let title: String
    let detail: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
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
