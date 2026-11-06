import AppKit
import FotolarkKit
import Observation
import Photos
import UniformTypeIdentifiers

/// The Apple Photos library as a place to import from: all photos or one album, with
/// the import window's filters, date folders and conversions.
@MainActor @Observable
final class PhotosLibrarySource: ImportSource {
    struct AlbumChoice: Identifiable, Hashable {
        let id: String
        let title: String
        let count: Int
    }

    private(set) var candidates: [ImportCandidate] = []
    private(set) var statusMessage: String? = "Asking for access to your Photos library…"
    private(set) var isLoading = true
    private(set) var albums: [AlbumChoice] = []
    /// nil = every photo.
    var albumID: String? { didSet { if albumID != oldValue { load() } } }

    private var assets: [String: PHAsset] = [:]
    private var thumbnails: [String: CGImage] = [:]
    private var requested: Set<String> = []
    private let imageManager = PHCachingImageManager()
    static let liveSuffix = "#live"

    init() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            switch status {
            case .authorized, .limited:
                loadAlbums()
                load()
            default:
                isLoading = false
                statusMessage = "Fotolark doesn’t have permission to see your Photos library. Turn it on in System Settings › Privacy & Security › Photos."
            }
        }
    }

    var title: String { "Apple Photos" }
    var systemImage: String { "photo.on.rectangle.angled" }
    /// Photos are never deleted from the Photos library from here.
    var canDelete: Bool { false }

    private func loadAlbums() {
        var out: [AlbumChoice] = []
        for type in [PHAssetCollectionType.album, .smartAlbum] {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { c, _, _ in
                let count = PHAsset.fetchAssets(in: c, options: nil).count
                if count > 0 { out.append(AlbumChoice(id: c.localIdentifier, title: c.localizedTitle ?? "Album", count: count)) }
            }
        }
        albums = out.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func load() {
        isLoading = true
        statusMessage = "Reading your Photos library…"
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let result: PHFetchResult<PHAsset>
        if let albumID, let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject {
            result = PHAsset.fetchAssets(in: album, options: options)
        } else {
            result = PHAsset.fetchAssets(with: options)
        }
        var list: [ImportCandidate] = []
        var map: [String: PHAsset] = [:]
        result.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            let main = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
            guard let main else { return }
            let id = asset.localIdentifier
            map[id] = asset
            list.append(ImportCandidate(id: id, name: main.originalFilename, fileSize: 0, date: asset.creationDate,
                                        typeIdentifier: main.uniformTypeIdentifier))
            // A Live Photo's clip, paired with the still by name like on a camera.
            if let clip = resources.first(where: { $0.type == .pairedVideo }) {
                let base = (main.originalFilename as NSString).deletingPathExtension
                let ext = (clip.originalFilename as NSString).pathExtension
                list.append(ImportCandidate(id: id + Self.liveSuffix, name: base + "." + (ext.isEmpty ? "MOV" : ext),
                                            fileSize: 0, date: asset.creationDate, typeIdentifier: clip.uniformTypeIdentifier))
            }
        }
        assets = map
        candidates = list
        isLoading = false
        statusMessage = list.isEmpty ? "No photos here." : nil
    }

    func thumbnail(for id: String) -> CGImage? { thumbnails[id] }

    func requestThumbnail(for id: String) {
        guard thumbnails[id] == nil, !requested.contains(id), let asset = assets[id] else { return }
        requested.insert(id)
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        Self.requestImage(Unchecked(imageManager), asset: Unchecked(asset), options: Unchecked(options)) { [weak self] cg in
            self?.thumbnails[id] = cg.value
        }
    }

    /// Copies the photo as it looks in Photos now (with any edits made there), or a
    /// Live Photo's clip. Photos in iCloud are downloaded first.
    func download(_ id: String, to folder: URL) async throws -> URL {
        let isClip = id.hasSuffix(Self.liveSuffix)
        let assetID = isClip ? String(id.dropLast(Self.liveSuffix.count)) : id
        guard let asset = assets[assetID] else { throw CocoaError(.fileNoSuchFile) }
        let resources = PHAssetResource.assetResources(for: asset)
        let original = resources.first { $0.type == .photo || $0.type == .video }
        let resource: PHAssetResource?
        if isClip {
            resource = resources.first { $0.type == .fullSizePairedVideo } ?? resources.first { $0.type == .pairedVideo }
        } else {
            resource = resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo } ?? original
        }
        guard let resource else { throw CocoaError(.fileNoSuchFile) }
        // Keep the original's name; an edited version may have a different extension.
        let base = ((original?.originalFilename ?? resource.originalFilename) as NSString).deletingPathExtension
        let ext = (resource.originalFilename as NSString).pathExtension
        let target = folder.appendingPathComponent(UUID().uuidString + "-" + base + "." + ext)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options)
        return target
    }

    func delete(_ ids: [String]) async -> [String] { [] }

    /// Photos may answer on another queue; the image is handed to the main actor.
    nonisolated private static func requestImage(_ manager: Unchecked<PHCachingImageManager>, asset: Unchecked<PHAsset>,
                                                 options: Unchecked<PHImageRequestOptions>,
                                                 done: @escaping @MainActor (Unchecked<CGImage>) -> Void) {
        manager.value.requestImage(for: asset.value, targetSize: CGSize(width: 300, height: 300), contentMode: .aspectFit,
                                   options: options.value) { image, _ in
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let boxed = Unchecked(cg)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(boxed) } }
        }
    }

    func asset(_ id: String) -> PHAsset? { assets[id] }
}

/// Editing a picture from Apple Photos: Fotolark works on a copy, and Save to Photos
/// hands the result back as a Photos edit. Photos keeps the original (Revert to
/// Original there undoes it), and Fotolark stores its edits with it, so opening the
/// picture again picks up where you left off.
@MainActor
final class PhotosEditSession {
    nonisolated static let format = "com.purehungerlabs.fotolark"
    nonisolated static let formatVersion = "1"

    let asset: PHAsset
    let input: PHContentEditingInput
    /// The copy being edited.
    let workingURL: URL

    private init(asset: PHAsset, input: PHContentEditingInput, workingURL: URL) {
        self.asset = asset
        self.input = input
        self.workingURL = workingURL
    }

    static func begin(_ asset: PHAsset, store: RecipeStore) async throws -> PhotosEditSession {
        let input = try await requestInput(Unchecked(asset)).value
        guard let source = input.fullSizeImageURL else { throw CocoaError(.fileReadUnknown) }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fotolark/Photos Edits", isDirectory: true)
            .appendingPathComponent(asset.localIdentifier.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = PHAssetResource.assetResources(for: asset).first { $0.type == .photo }?.originalFilename
            ?? source.lastPathComponent
        let working = folder.appendingPathComponent((name as NSString).deletingPathExtension)
            .appendingPathExtension(source.pathExtension)
        try FileManager.default.copyItem(at: source, to: working)
        // Picking up an earlier Fotolark edit: Photos handed back the original, so the
        // saved recipe applies to it again.
        if let data = input.adjustmentData, data.formatIdentifier == format,
           let recipe = try? JSONDecoder().decode(EditRecipe.self, from: data.data) {
            try? store.save(recipe, for: working)
        }
        return PhotosEditSession(asset: asset, input: input, workingURL: working)
    }

    /// Renders the edited photo and saves it into Photos as an edit of the original.
    func save(_ recipe: EditRecipe, engine: EditEngine) async throws {
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: Self.format, formatVersion: Self.formatVersion,
                                                 data: try JSONEncoder().encode(recipe))
        let working = workingURL, target = output.renderedContentURL
        try await Task.detached(priority: .userInitiated) {
            let jpeg = try ImageExporter.encode(source: working, recipe: recipe,
                                                options: ExportOptions(format: .jpeg, quality: 0.93), engine: engine)
            try jpeg.write(to: target, options: .atomic)
        }.value
        try await Self.commit(Unchecked(output), to: Unchecked(asset))
    }

    // Photos runs these callbacks on its own queues, so they must not belong to the
    // main actor (Swift stops the app if they do).

    nonisolated private static func requestInput(_ asset: Unchecked<PHAsset>) async throws -> Unchecked<PHContentEditingInput> {
        // Made here so the adjustment check (which Photos calls on its own queue) isn't
        // tied to the main actor.
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { $0.formatIdentifier == format && $0.formatVersion == formatVersion }
        return try await withCheckedThrowingContinuation { cont in
            asset.value.requestContentEditingInput(with: options) { input, info in
                if let input { cont.resume(returning: Unchecked(input)) } else {
                    cont.resume(throwing: (info[PHContentEditingInputErrorKey] as? Error) ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }

    nonisolated private static func commit(_ output: Unchecked<PHContentEditingOutput>, to asset: Unchecked<PHAsset>) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset.value).contentEditingOutput = output.value
        }
    }
}
