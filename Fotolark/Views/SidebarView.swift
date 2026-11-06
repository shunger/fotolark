import FotolarkKit
import SwiftUI

/// Watched folders and every folder inside them that holds photos, with counts.
struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var hovered: FolderLibrary.Root.ID?

    private var library: FolderLibrary { model.library }

    var body: some View {
        List(selection: Binding(get: { model.source }, set: { newValue in
            model.closeEditor()
            model.source = newValue
        })) {
            Section("Library") {
                Label("All Photos", systemImage: "calendar")
                    .badge(model.index.count)
                    .tag(AppModel.Source.timeline)
                    .help("Every photo in your folders, by month")
                Label("People", systemImage: "person.2")
                    .badge(model.people.count)
                    .tag(AppModel.Source.people)
                    .help("Faces found in your photos, grouped by person")
                ForEach(model.people) { person in
                    Label(person.name, systemImage: "person.crop.circle")
                        .padding(.leading, 14)
                        .tag(AppModel.Source.person(person.id))
                }
                if case .search(let text) = model.source {
                    Label("“\(text)”", systemImage: "magnifyingglass")
                        .tag(AppModel.Source.search(text))
                }
            }

            Section("Import") {
                ForEach(model.allImportSources, id: \.importKey) { source in
                    Label(source.title, systemImage: source.systemImage)
                        .tag(AppModel.Source.importing(AppModel.importKey(source)))
                        .contextMenu {
                            if let folder = source as? FolderImportSource {
                                Button("Remove") { model.removeFolderImport(folder) }
                            }
                        }
                }
                if model.photosLibrary == nil {
                    Button {
                        model.showPhotosLibrary()
                    } label: {
                        Label("Apple Photos", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.plain)
                    .help("Copy photos out of your Photos library into folders, or edit them and save back to Photos")
                }
                Button {
                    model.importFromFolderWithPanel()
                } label: {
                    Label("From Folder or Drive…", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                if model.devices.devices.isEmpty {
                    Text("Plug in an iPhone, camera or card reader to import from it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !model.openedPhotos.isEmpty {
                Section("Opened") {
                    Label("Opened Photos", systemImage: "photo.stack")
                        .badge(model.openedPhotos.count)
                        .tag(AppModel.Source.opened)
                }
            }

            Section {
                ForEach(model.albums) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .badge(album.items.count)
                        .tag(AppModel.Source.album(album.id))
                        .contextMenu {
                            Button("Rename…") { model.sheet = .renameAlbum(album.id) }
                            Button("Delete Album") { model.deleteAlbum(album.id) }
                        }
                        .help("\(album.name): photos from any folder. Deleting the album leaves the photos alone.")
                }
                Button {
                    model.sheet = .newAlbum([])
                } label: {
                    Label("New Album…", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } header: {
                Text("Albums")
            }

            ForEach(library.roots) { root in
                Section {
                    if let folders = library.folders[root.id] {
                        ForEach(folders) { folder in
                            FolderRow(folder: folder, isRoot: folder.depth == 0, rootName: library.name(of: root))
                                .tag(AppModel.Source.folder(folder.url))
                        }
                    } else if library.isAvailable(root) {
                        Text("Looking for photos…").foregroundStyle(.secondary)
                    } else {
                        Label("Not available. Is the drive connected?", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .help(root.path)
                    }
                } header: {
                    HStack {
                        Text(library.name(of: root))
                        Spacer()
                        Button {
                            library.remove(root.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .opacity(hovered == root.id ? 1 : 0)
                        .help("Stop showing this folder (nothing is deleted)")
                        .accessibilityLabel("Remove \(library.name(of: root)) from the sidebar")
                    }
                    .onHover { hovered = $0 ? root.id : nil }
                }
            }

            if library.roots.isEmpty {
                Section("Folders") {
                    Text("Add a folder of photos to see it here.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search all photos")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // A solid footer, so folders scrolling underneath don't show through it.
            VStack(alignment: .leading, spacing: 6) {
                if let status = model.indexStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Fotolark looks at your photos in the background (faces, look-alikes and text in photos) so People and search can find them. Turn this off in Settings.")
                }
                HStack {
                    Button {
                        model.addFolderWithPanel()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    if library.isScanning { ProgressView().controlSize(.small) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
    }
}

private struct FolderRow: View {
    let folder: ScannedFolder
    let isRoot: Bool
    let rootName: String

    var body: some View {
        Label(folder.name, systemImage: isRoot ? "folder.fill" : "folder")
            .padding(.leading, CGFloat(max(folder.depth - 1, 0)) * 14)
            // Folders that only hold other folders (such as a year) show no count.
            .badge(folder.photoCount)
            .foregroundStyle(folder.photoCount == 0 && !isRoot ? .secondary : .primary)
            .help(folder.url.path)
            .accessibilityValue(folder.photoCount == 0 ? "holds folders" : "\(folder.photoCount) photos")
    }
}
