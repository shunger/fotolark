import AppKit
import FotolarkKit
import SwiftUI
import UniformTypeIdentifiers

/// Toolbar Share button: renders edited copies, then shows the Mac's Share menu (Mail,
/// Messages, AirDrop, Notes, Photos…).
struct ShareButton: View {
    @Bindable var model: AppModel
    @State private var anchor: NSView?
    @State private var isPreparing = false

    var body: some View {
        Button {
            share()
        } label: {
            if isPreparing { ProgressView().controlSize(.small) } else { Image(systemName: "square.and.arrow.up") }
        }
        .background(AnchorView(view: $anchor))
        .disabled(model.targetPhotos.isEmpty || isPreparing)
        .help("Share edited copies with Mail, Messages, AirDrop and more")
        .accessibilityLabel("Share")
    }

    private func share() {
        isPreparing = true
        Task {
            let items = await model.sharingItems()
            isPreparing = false
            guard !items.isEmpty, let anchor else { return }
            NSSharingServicePicker(items: items).show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }
}

/// Gives SwiftUI code an NSView to anchor AppKit popovers to.
private struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Dragging an edited photo out of the grid hands over an edited JPEG copy, made when
/// it's dropped (a "file promise"). Unedited photos are dragged as the original file.
final class EditedPhotoPromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    struct Payload {
        let photo: URL
        let recipe: EditRecipe
    }

    private let engine: EditEngine
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    init(engine: EditEngine) {
        self.engine = engine
    }

    func provider(for photo: URL, recipe: EditRecipe) -> NSFilePromiseProvider {
        let p = NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: self)
        p.userInfo = Payload(photo: photo, recipe: recipe)
        return p
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let payload = provider.userInfo as? Payload else { return "Photo.jpg" }
        return ImageExporter.fileName(for: payload.photo, format: .jpeg)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let payload = provider.userInfo as? Payload else {
            completionHandler(CocoaError(.fileWriteUnknown))
            return
        }
        do {
            try ImageExporter.export(source: payload.photo, recipe: payload.recipe,
                                     options: ExportOptions(format: .jpeg, quality: 0.92), to: url, engine: engine)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }
}
