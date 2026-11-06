import FotolarkKit
import SwiftUI

/// Stars, pick/reject and tags for one or more photos (in the Info panel).
struct LabelsEditor: View {
    @Bindable var model: AppModel
    let urls: [URL]
    @State private var newTag = ""

    private var all: [PhotoLabels] { urls.map { model.labels(for: $0) } }

    /// Every tag on any of the photos, with how many have it.
    private var tags: [(tag: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for l in all {
            for t in l.tags {
                let key = t.lowercased()
                if counts[key] == nil { order.append(t) }
                counts[key, default: 0] += 1
            }
        }
        return order.map { ($0, counts[$0.lowercased()] ?? 0) }
    }

    private var suggestions: [String] {
        let typed = newTag.trimmingCharacters(in: .whitespaces)
        let present = Set(tags.map { $0.tag.lowercased() })
        return model.knownTags
            .filter { !present.contains($0.lowercased()) }
            .filter { typed.isEmpty || $0.localizedCaseInsensitiveContains(typed) }
            .prefix(6).map { $0 }
    }

    var body: some View {
        let ratings = Set(all.map(\.rating))
        let flags = Set(all.map(\.flag))
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                StarRating(rating: ratings.count == 1 ? ratings.first! : nil) { model.applyLabel(.rating($0), to: urls) }
                Spacer()
                flagButton(.pick, current: flags.count == 1 ? flags.first! : nil,
                           symbol: "flag.fill", title: "Pick", tint: .green)
                flagButton(.reject, current: flags.count == 1 ? flags.first! : nil,
                           symbol: "xmark", title: "Reject", tint: .red)
            }

            if !tags.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(tags, id: \.tag) { item in
                        TagChip(tag: item.tag, partial: item.count < urls.count) {
                            model.applyLabel(.removeTag(item.tag), to: urls)
                        } addToAll: {
                            model.applyLabel(.addTag(item.tag), to: urls)
                        }
                    }
                }
            }
            TextField(urls.count > 1 ? "Add a tag to \(urls.count) photos" : "Add a tag", text: $newTag)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTyped)
            if !suggestions.isEmpty && (!newTag.isEmpty || tags.isEmpty) {
                FlowLayout(spacing: 5) {
                    ForEach(suggestions, id: \.self) { s in
                        Button(s) { model.applyLabel(.addTag(s), to: urls); newTag = "" }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("Add the tag “\(s)”")
                    }
                }
            }
            if model.writesTagsToFiles {
                Text("Tags are also saved inside the photo files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func addTyped() {
        // Commas add several at once.
        for part in newTag.split(separator: ",") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { model.applyLabel(.addTag(t), to: urls) }
        }
        newTag = ""
    }

    private func flagButton(_ flag: PhotoLabels.Flag, current: PhotoLabels.Flag?, symbol: String, title: String,
                            tint: Color) -> some View {
        let on = current == flag
        return Button {
            model.applyLabel(.flag(on ? .none : flag), to: urls)
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(on ? .white : .secondary)
                .frame(width: 24, height: 20)
                .background(on ? tint : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .help(on ? "Clear the flag (U)" : "\(title) (\(flag == .pick ? "P" : "X"))")
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Five stars; clicking the current rating clears it.
struct StarRating: View {
    /// nil when the selected photos have different ratings.
    let rating: Int?
    let set: (Int) -> Void
    @State private var hover: Int?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                let shown = hover ?? rating ?? 0
                Image(systemName: n <= shown ? "star.fill" : "star")
                    .foregroundStyle(n <= shown ? Color.orange : (rating == nil ? Color.secondary.opacity(0.5) : .secondary))
                    .font(.system(size: 14))
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture { set(rating == n ? 0 : n) }
                    .onHover { hover = $0 ? n : (hover == n ? nil : hover) }
            }
        }
        .help(rating == nil ? "These photos have different ratings" : "Rating (keys 1–5, 0 clears)")
        .accessibilityElement()
        .accessibilityLabel("Rating")
        .accessibilityValue(rating.map { $0 == 0 ? "No stars" : $0 == 1 ? "1 star" : "\($0) stars" } ?? "Mixed")
        .accessibilityAdjustableAction { direction in
            let r = rating ?? 0
            switch direction {
            case .increment: set(min(r + 1, 5))
            case .decrement: set(max(r - 1, 0))
            @unknown default: break
            }
        }
    }
}

private struct TagChip: View {
    let tag: String
    /// Only some of the selected photos have it.
    let partial: Bool
    let remove: () -> Void
    let addToAll: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(tag).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(partial ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.18), in: Capsule())
        .overlay { if partial { Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(.secondary) } }
        .contextMenu {
            if partial { Button("Add to All Selected Photos", action: addToAll) }
            Button("Remove", action: remove)
        }
        .help(partial ? "Only some of the selected photos have this tag. Right-click to add it to all." : tag)
    }
}

/// Lays children out in rows, wrapping when a row is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !row.items.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// Names a new album, or renames one.
struct AlbumNameSheet: View {
    @Bindable var model: AppModel
    /// Photos for a new album; ignored when renaming.
    var photos: [URL] = []
    var renaming: Album.ID?
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(renaming == nil ? "New Album" : "Rename Album").font(.title2.weight(.semibold))
            TextField("Album name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(commit)
            if renaming == nil {
                Text(photos.isEmpty
                     ? "Add photos later from the grid’s right-click menu."
                     : "\(photos.count == 1 ? "The selected photo goes" : "The \(photos.count) selected photos go") into the album. The files stay where they are.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 320, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(renaming == nil ? "Create" : "Rename", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            if let renaming, let album = model.albums.first(where: { $0.id == renaming }) { name = album.name }
        }
    }

    private func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        dismiss()
        if let renaming {
            model.renameAlbum(renaming, to: name)
        } else {
            model.createAlbum(named: name, with: photos)
        }
    }
}
