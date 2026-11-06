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
            if !model.openedPhotos.isEmpty {
                Section("Opened") {
                    Label("Opened Photos", systemImage: "photo.stack")
                        .badge(model.openedPhotos.count)
                        .tag(AppModel.Source.opened)
                }
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
        .safeAreaInset(edge: .bottom) {
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
            .padding(10)
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
            .badge(folder.photoCount)
            .help(folder.url.path)
            .accessibilityValue("\(folder.photoCount) photos")
    }
}
