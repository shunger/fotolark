import AppKit
import FotolarkKit
import ImageCaptureCore
import Observation
import UniformTypeIdentifiers

/// Somewhere photos can be imported from: a phone, camera, memory card or folder.
@MainActor
protocol ImportSource: AnyObject, Observable {
    var title: String { get }
    var systemImage: String { get }
    var candidates: [ImportCandidate] { get }
    /// Shown instead of the photos while the source isn't ready (e.g. "Unlock your iPhone").
    var statusMessage: String? { get }
    var isLoading: Bool { get }
    var canDelete: Bool { get }
    func thumbnail(for id: ImportCandidate.ID) -> CGImage?
    func requestThumbnail(for id: ImportCandidate.ID)
    /// Copies the photo into `folder` and returns the copy.
    func download(_ id: ImportCandidate.ID, to folder: URL) async throws -> URL
    func delete(_ ids: [ImportCandidate.ID]) async -> [String]
}

// MARK: - Devices (iPhone, iPad, cameras, SD cards with a DCIM folder)

/// Watches for phones, cameras and memory cards being plugged in.
@MainActor @Observable
final class DeviceBrowser: NSObject {
    private(set) var devices: [CameraImportSource] = []
    private let browser = ICDeviceBrowser()

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue:
            ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }
}

extension DeviceBrowser: ICDeviceBrowserDelegate {
    // Called on whatever queue ImageCaptureCore likes; the work happens on the main actor.
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        let me = Unchecked(self), cam = Unchecked(camera)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard !me.value.devices.contains(where: { $0.camera === cam.value }) else { return }
                me.value.devices.append(CameraImportSource(camera: cam.value))
            }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        let me = Unchecked(self), dev = Unchecked(device)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { me.value.devices.removeAll { $0.camera === dev.value } }
        }
    }
}

@MainActor @Observable
final class CameraImportSource: NSObject, ImportSource {
    let camera: ICCameraDevice
    private(set) var candidates: [ImportCandidate] = []
    private(set) var statusMessage: String?
    private(set) var isLoading = true
    private var files: [String: ICCameraFile] = [:]
    private var thumbnails: [String: CGImage] = [:]
    private var requested: Set<String> = []

    init(camera: ICCameraDevice) {
        self.camera = camera
        super.init()
        camera.delegate = self
        statusMessage = "Connecting…"
        camera.requestOpenSession()
    }

    var title: String { camera.name ?? "Camera" }

    var systemImage: String {
        let name = (camera.name ?? "").lowercased()
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if camera.transportType == ICDeviceTransport.transportTypeMassStorage.rawValue { return "sdcard" }
        return "camera"
    }

    var canDelete: Bool { camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue) }

    func thumbnail(for id: String) -> CGImage? { thumbnails[id] }

    func requestThumbnail(for id: String) {
        guard thumbnails[id] == nil, !requested.contains(id), let file = files[id] else { return }
        requested.insert(id)
        if let thumb = file.thumbnail {
            thumbnails[id] = thumb
        } else {
            file.requestThumbnail()
        }
    }

    func download(_ id: String, to folder: URL) async throws -> URL {
        guard let file = files[id] else { throw CocoaError(.fileNoSuchFile) }
        let name = try await Self.requestDownload(Unchecked(file), to: folder)
        return folder.appendingPathComponent(name)
    }

    func delete(_ ids: [String]) async -> [String] {
        await Self.requestDelete(Unchecked(ids.compactMap { files[$0] }), on: Unchecked(camera))
    }

    // ImageCaptureCore calls back on its own queue, so these callbacks must not belong
    // to the main actor (Swift stops the app if they do).

    nonisolated private static func requestDownload(_ file: Unchecked<ICCameraFile>, to folder: URL) async throws -> String {
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: folder,
            .overwrite: true,
        ]
        return try await withCheckedThrowingContinuation { continuation in
            file.value.requestDownload(options: options) { filename, error in
                if let filename { continuation.resume(returning: filename) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    nonisolated private static func requestDelete(_ files: Unchecked<[ICCameraFile]>,
                                                  on camera: Unchecked<ICCameraDevice>) async -> [String] {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            camera.value.requestDeleteFiles(files.value, deleteFailed: { failed in
                if once.claim() { continuation.resume(returning: failed.values.compactMap { $0.name }) }
            }, completion: { _, _ in
                if once.claim() { continuation.resume(returning: []) }
            })
        }
    }

    /// Name, size and date identify a file on the device for this session.
    nonisolated static func id(for file: ICCameraFile) -> String {
        "\(file.name ?? "")|\(file.fileSize)|\(Int(file.creationDate?.timeIntervalSince1970 ?? 0))|\(file.ptpObjectHandle)"
    }

    fileprivate func refreshCandidates() {
        var list: [ImportCandidate] = []
        files = [:]
        for case let file as ICCameraFile in camera.mediaFiles ?? [] {
            let id = Self.id(for: file)
            files[id] = file
            list.append(ImportCandidate(id: id, name: file.name ?? "Photo", fileSize: file.fileSize,
                                        date: file.exifCreationDate ?? file.fileCreationDate ?? file.creationDate,
                                        typeIdentifier: file.uti))
        }
        candidates = list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}

extension CameraImportSource: ICCameraDeviceDelegate {
    // ImageCaptureCore may call these on any queue; each hands its news to the main actor.

    nonisolated private func onMain(_ work: @escaping @MainActor (CameraImportSource) -> Void) {
        let me = Unchecked(self)
        DispatchQueue.main.async { MainActor.assumeIsolated { work(me.value) } }
    }

    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        let message = error?.localizedDescription
        onMain { me in
            if let message {
                me.statusMessage = "Couldn’t connect: \(message)"
                me.isLoading = false
            } else {
                me.statusMessage = me.camera.isAccessRestrictedAppleDevice ? Self.lockedMessage : "Reading photos…"
            }
        }
    }

    static let lockedMessage = "Unlock your iPhone or iPad. If it asks “Trust This Computer?”, tap Trust."

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        onMain { me in
            me.refreshCandidates()
            me.isLoading = false
            me.statusMessage = me.candidates.isEmpty ? "No photos on \(me.title)." : nil
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        onMain { me in if !me.isLoading { me.refreshCandidates() } }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        onMain { me in me.refreshCandidates() }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem,
                                  error: (any Error)?) {
        guard let thumbnail, let file = item as? ICCameraFile else { return }
        let id = Self.id(for: file)
        let image = Unchecked(thumbnail)
        onMain { me in me.thumbnails[id] = image.value }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?,
                                  for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        onMain { me in me.refreshCandidates() }
    }
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        onMain { me in me.statusMessage = me.isLoading ? "Reading photos…" : nil }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        onMain { me in me.statusMessage = Self.lockedMessage }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {}
    nonisolated func didRemove(_ device: ICDevice) {}
}

/// Hands a value that isn't marked thread-safe between queues, where only one side
/// uses it at a time (framework objects passed to and from callbacks).
struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Lets a continuation be resumed by whichever of two callbacks comes first.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}

// MARK: - A folder or drive

/// Photos in a folder or on a drive the person chose (searched through subfolders).
@MainActor @Observable
final class FolderImportSource: ImportSource {
    let folder: URL
    private(set) var candidates: [ImportCandidate] = []
    private(set) var isLoading = true
    private(set) var statusMessage: String? = "Looking for photos…"
    private var thumbnails: [String: CGImage] = [:]
    private var requested: Set<String> = []
    private let store: ThumbnailStore

    init(folder: URL, thumbnails: ThumbnailStore) {
        self.folder = folder
        store = thumbnails
        Task {
            candidates = await Task.detached(priority: .userInitiated) { [folder] in
                Self.scan(folder)
            }.value
            isLoading = false
            statusMessage = candidates.isEmpty ? "No photos found in “\(folder.lastPathComponent)”." : nil
        }
    }

    /// Photos and videos anywhere under `folder` (hidden files and packages skipped).
    nonisolated static func scan(_ folder: URL) -> [ImportCandidate] {
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [ImportCandidate] = []
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                  let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image) || type.conforms(to: .movie) else { continue }
            let date = type.conforms(to: .image) ? PhotoMetadata.dateTaken(url) : nil
            out.append(ImportCandidate(id: url.path, name: url.lastPathComponent, fileSize: Int64(v.fileSize ?? 0),
                                       date: date ?? v.creationDate, typeIdentifier: type.identifier))
        }
        return out.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    var title: String { folder.lastPathComponent }
    var systemImage: String { "externaldrive" }
    var canDelete: Bool { true }

    func thumbnail(for id: String) -> CGImage? { thumbnails[id] }

    func requestThumbnail(for id: String) {
        guard thumbnails[id] == nil, !requested.contains(id) else { return }
        requested.insert(id)
        let url = URL(fileURLWithPath: id)
        guard ImageLoader.canOpen(url) else { return }  // videos show an icon instead
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey]) else { return }
        let photo = ScannedPhoto(url: url, fileSize: Int64(v.fileSize ?? 0), modified: v.contentModificationDate ?? .distantPast,
                                 created: v.creationDate ?? .distantPast)
        Task {
            if let image = await store.thumbnail(for: photo, recipe: nil, maxPixelSize: 256) { thumbnails[id] = image }
        }
    }

    func download(_ id: String, to folder: URL) async throws -> URL {
        let source = URL(fileURLWithPath: id)
        let target = folder.appendingPathComponent(UUID().uuidString + "-" + source.lastPathComponent)
        try await Task.detached { try FileManager.default.copyItem(at: source, to: target) }.value
        return target
    }

    /// Moves the originals to the Trash (the drive's own Trash for external drives).
    func delete(_ ids: [String]) async -> [String] {
        var failed: [String] = []
        for id in ids {
            let url = URL(fileURLWithPath: id)
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failed.append(url.lastPathComponent) }
        }
        return failed
    }
}
