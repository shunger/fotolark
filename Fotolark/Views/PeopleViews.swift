import AppKit
import FotolarkKit
import SwiftUI

/// Faces found in the photos, grouped by person. Name a group to make it a person;
/// naming two groups the same joins them.
struct PeopleView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("People").font(.title2.weight(.semibold))
                    Text("Faces are found and grouped on this Mac; nothing is sent anywhere. Name a group to keep it. Give two groups the same name to join them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Group faces").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("Strictly").font(.caption2)
                        Slider(value: $model.faceThreshold, in: 0.2...0.7).frame(width: 140)
                            .accessibilityLabel("How alike faces must be to group them")
                        Text("Loosely").font(.caption2)
                    }
                }
                .help("If one group mixes two people, group more strictly. If one person is split into many groups, group more loosely or give the groups the same name.")
            }
            .padding(16)
            Divider()
            if model.faceGroups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2").font(.system(size: 40, weight: .light)).foregroundStyle(.secondary)
                    Text(model.indexStatus ?? "No faces found yet").font(.title3)
                    if !model.analyzesPhotos {
                        Text("Looking for faces is turned off in Settings.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                        ForEach(model.faceGroups) { group in
                            FaceGroupCard(model: model, group: group)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

private struct FaceGroupCard: View {
    @Bindable var model: AppModel
    let group: FaceGroup
    @State private var name = ""

    var body: some View {
        VStack(spacing: 6) {
            Button {
                model.source = group.person.map { .person($0.id) } ?? .faceGroup(group.id)
            } label: {
                FaceThumb(photo: group.faces[0].photo, face: group.faces[0].face)
                    .frame(width: 120, height: 120)
                    .clipShape(Circle())
                    .contentShape(Circle())
                    .overlay(Circle().strokeBorder(.quaternary))
            }
            .buttonStyle(.plain)
            .help("Show the photos")
            if let person = group.person {
                Text(person.name).font(.headline).lineLimit(1)
                    .contextMenu {
                        Button("Rename…") { name = person.name }
                        Button("Forget This Person", role: .destructive) { model.forgetPerson(person.id) }
                    }
            } else {
                TextField("Add a name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .onSubmit { model.nameFaces(group, as: name) }
            }
            Text(group.faces.count == 1 ? "1 photo" : "\(Set(group.faces.map(\.photo)).count) photos")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.person?.name ?? "Unnamed person")
    }
}

/// A face cut out of its photo.
struct FaceThumb: View {
    let photo: URL
    let face: FaceInfo
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .clipped()
        .task(id: face.id) {
            let face = face, photo = photo
            image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let cg = try? ImageLoader.loadPreview(photo, maxPixelSize: 800) else { return nil }
                let e = cg.extent
                let side = max(face.width * e.width, face.height * e.height) * 1.5
                let cx = e.minX + (face.x + face.width / 2) * e.width
                let cy = e.maxY - (face.y + face.height / 2) * e.height
                let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side).intersection(e)
                return CIContext().createCGImage(cg.cropped(to: rect), from: rect)
            }.value
        }
    }
}

/// Identical copies and look-alikes, with the best of each group kept.
struct DuplicatesSheet: View {
    @Bindable var model: AppModel
    let photos: [ScannedPhoto]
    @State private var exact: [[URL]] = []
    @State private var similar: [[URL]] = []
    @State private var trashing: Set<URL> = []
    @State private var status: String? = "Comparing photos…"
    @State private var includeSimilar = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Duplicates").font(.title2.weight(.semibold))
                Spacer()
                Toggle("Include look-alikes", isOn: $includeSimilar)
                    .help("Also show photos that look nearly the same (resized or edited copies, bursts), not only identical files")
            }
            .padding(16)
            Divider()
            if let status {
                VStack(spacing: 10) { ProgressView(); Text(status).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shownGroups.isEmpty {
                Text("No duplicates among these \(photos.count) photos.")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Photos marked with a cross go to the Trash; click a photo to switch. The best copy of each group (most pixels, then edited) is kept.")
                            .font(.callout).foregroundStyle(.secondary)
                        if !exact.isEmpty { section("Identical copies", exact) }
                        if includeSimilar && !similar.isEmpty { section("Look nearly the same", similar) }
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Text(trashingCount == 0 ? "Nothing marked" : "\(trashingCount) marked for the Trash")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Move \(trashingCount) to Trash", role: .destructive) {
                    model.trash(Array(trashing.filter { url in shownGroups.contains { $0.contains(url) } }))
                    dismiss()
                }
                .disabled(trashingCount == 0)
            }
            .padding(16)
        }
        .frame(width: 760, height: 560)
        .task { await find() }
    }

    private var shownGroups: [[URL]] { exact + (includeSimilar ? similar : []) }
    private var trashingCount: Int { trashing.filter { url in shownGroups.contains { $0.contains(url) } }.count }

    private func section(_ title: String, _ groups: [[URL]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(groups, id: \.self) { group in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(group, id: \.self) { url in
                            let gone = trashing.contains(url)
                            Button {
                                if gone { trashing.remove(url) } else { trashing.insert(url) }
                            } label: {
                                VStack(spacing: 3) {
                                    ZStack(alignment: .topTrailing) {
                                        DuplicateThumb(photo: photos.first { $0.url == url }, store: model.thumbnails,
                                                       recipe: model.recipes[url])
                                            .frame(width: 130, height: 100)
                                            .opacity(gone ? 0.4 : 1)
                                        Image(systemName: gone ? "xmark.circle.fill" : "checkmark.circle.fill")
                                            .foregroundStyle(.white, gone ? Color.red : Color.green)
                                            .font(.title3)
                                            .padding(3)
                                    }
                                    Text(url.lastPathComponent).font(.caption2).lineLimit(1).truncationMode(.middle)
                                        .frame(width: 130)
                                    Text(url.deletingLastPathComponent().lastPathComponent).font(.caption2)
                                        .foregroundStyle(.secondary).lineLimit(1).frame(width: 130)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(url.lastPathComponent), \(gone ? "goes to the Trash" : "kept")")
                        }
                    }
                }
                Divider()
            }
        }
    }

    private func find() async {
        let photos = photos, analysis = model.analysis, context = model.engine.context
        let edited = Set(model.recipes.keys)
        let dates = model.datesTaken(for: photos.map(\.url))
        status = "Looking for identical files…"
        let exactGroups = await Task.detached(priority: .userInitiated) { DuplicateFinder.exactGroups(photos) }.value
        // Look-alikes need each photo looked at; most already are, from the background pass.
        let todo = analysis.needsAnalysis(photos)
        for (i, p) in todo.enumerated() {
            status = "Looking at photos: \(i + 1) of \(todo.count)…"
            let a = await Task.detached(priority: .userInitiated) { PhotoAnalyzer.analyze(p.url, context: context) }.value
            analysis.set(a ?? PhotoAnalysis(fingerprint: nil, faces: []), for: p)
        }
        if !todo.isEmpty { analysis.save() }
        let inExact = Set(exactGroups.flatMap { $0 })
        let similarGroups = await Task.detached(priority: .userInitiated) {
            DuplicateFinder.similarGroups(photos.filter { !inExact.contains($0.url) }, dates: dates, store: analysis)
        }.value
        var marked = Set<URL>()
        for group in exactGroups + similarGroups {
            let keep = await Task.detached { DuplicateFinder.best(of: group, edited: edited) }.value
            marked.formUnion(group.filter { $0 != keep })
        }
        exact = exactGroups
        similar = similarGroups
        trashing = marked
        status = nil
    }
}

private struct DuplicateThumb: View {
    let photo: ScannedPhoto?
    let store: ThumbnailStore
    let recipe: EditRecipe?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
        }
        .task {
            guard let photo else { return }
            image = await store.thumbnail(for: photo, recipe: recipe, maxPixelSize: 260)
        }
    }
}
