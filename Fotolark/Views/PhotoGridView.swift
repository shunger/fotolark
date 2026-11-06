import AppKit
import FotolarkKit
import SwiftUI

/// The thumbnail grid. Built on NSCollectionView, which reuses cells so folders with
/// tens of thousands of photos scroll smoothly, and brings native selection, arrow-key
/// navigation, rubber-band selection and dragging to Finder or Mail.
struct PhotoGridView: NSViewRepresentable {
    let photos: [ScannedPhoto]
    let recipes: [URL: EditRecipe]
    @Binding var selection: Set<URL>
    let thumbnailSize: CGFloat
    let thumbnails: ThumbnailStore
    let onOpen: (URL) -> Void
    let makeMenu: () -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        let collection = GridCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.identifier)
        collection.delegate = context.coordinator
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.coordinator = context.coordinator
        collection.setAccessibilityLabel("Photos")

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        context.coordinator.attach(collection)
        context.coordinator.update(with: self)
        DispatchQueue.main.async { collection.window?.makeFirstResponder(collection) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
        var parent: PhotoGridView
        private var dataSource: NSCollectionViewDiffableDataSource<Int, URL>?
        private weak var collection: NSCollectionView?
        private var byURL: [URL: ScannedPhoto] = [:]
        private var shownURLs: [URL] = []
        private var shownRecipes: [URL: EditRecipe] = [:]
        private var itemSize: CGFloat = 0
        private var isApplyingSelection = false

        init(_ parent: PhotoGridView) { self.parent = parent }

        func attach(_ collection: NSCollectionView) {
            self.collection = collection
            dataSource = NSCollectionViewDiffableDataSource<Int, URL>(collectionView: collection) {
                [weak self] collectionView, indexPath, url in
                let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath)
                if let self, let cell = item as? PhotoGridItem, let photo = self.byURL[url] {
                    cell.configure(photo: photo, recipe: self.parent.recipes[url], store: self.parent.thumbnails,
                                   pointSize: self.itemSize)
                }
                return item
            }
        }

        func update(with parent: PhotoGridView) {
            self.parent = parent
            guard let collection, let dataSource else { return }

            if itemSize != parent.thumbnailSize {
                itemSize = parent.thumbnailSize
                collection.collectionViewLayout?.invalidateLayout()
                refreshVisible()
            }

            let urls = parent.photos.map(\.url)
            byURL = Dictionary(parent.photos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            if urls != shownURLs {
                shownURLs = urls
                var snapshot = NSDiffableDataSourceSnapshot<Int, URL>()
                snapshot.appendSections([0])
                snapshot.appendItems(urls)
                dataSource.apply(snapshot, animatingDifferences: false)
            }

            // Thumbnails whose edits changed.
            if parent.recipes != shownRecipes {
                let changed = Set(parent.recipes.keys).union(shownRecipes.keys).filter { parent.recipes[$0] != shownRecipes[$0] }
                shownRecipes = parent.recipes
                refreshVisible(only: changed)
            }

            applySelection(parent.selection)
        }

        private func refreshVisible(only urls: Set<URL>? = nil) {
            guard let collection, let dataSource else { return }
            for indexPath in collection.indexPathsForVisibleItems() {
                guard let url = dataSource.itemIdentifier(for: indexPath), urls?.contains(url) ?? true,
                      let photo = byURL[url],
                      let cell = collection.item(at: indexPath) as? PhotoGridItem else { continue }
                cell.configure(photo: photo, recipe: parent.recipes[url], store: parent.thumbnails, pointSize: itemSize)
            }
        }

        private func applySelection(_ selection: Set<URL>) {
            guard let collection, let dataSource else { return }
            let current = Set(collection.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
            guard current != selection else { return }
            isApplyingSelection = true
            let paths = Set(selection.compactMap { dataSource.indexPath(for: $0) })
            collection.selectionIndexPaths = paths
            if let first = paths.min(), selection.count == 1 {
                collection.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge)
            }
            isApplyingSelection = false
        }

        private func selectionChanged() {
            guard !isApplyingSelection, let collection, let dataSource else { return }
            let urls = Set(collection.selectionIndexPaths.compactMap { dataSource.itemIdentifier(for: $0) })
            if urls != parent.selection { parent.selection = urls }
        }

        // MARK: Delegate

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
                            sizeForItemAt indexPath: IndexPath) -> NSSize {
            NSSize(width: itemSize, height: itemSize + PhotoGridItem.labelHeight)
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            (item as? PhotoGridItem)?.cancelLoading()
        }

        // Dragging a photo out copies the file (to Finder, Mail, Messages…).
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            dataSource?.itemIdentifier(for: indexPath) as NSURL?
        }

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            true
        }

        // MARK: Called by the collection view

        func open(at indexPath: IndexPath?) {
            if let indexPath, let url = dataSource?.itemIdentifier(for: indexPath) {
                parent.onOpen(url)
            } else if let first = collection?.selectionIndexPaths.min(), let url = dataSource?.itemIdentifier(for: first) {
                parent.onOpen(url)
            }
        }

        func menu() -> NSMenu { parent.makeMenu() }
    }
}

/// Handles double-click, Return and the right-click menu.
final class GridCollectionView: NSCollectionView {
    weak var coordinator: PhotoGridView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            if let path = indexPathForItem(at: point) { coordinator?.open(at: path) }
        }
    }

    override func keyDown(with event: NSEvent) {
        // Return or Enter opens the selected photo.
        if event.keyCode == 36 || event.keyCode == 76 {
            coordinator?.open(at: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point), !selectionIndexPaths.contains(path) {
            // Right-clicking an unselected photo selects just that one, as in Finder.
            deselectAll(nil)
            selectItems(at: [path], scrollPosition: [])
            delegate?.collectionView?(self, didSelectItemsAt: [path])
        }
        return selectionIndexPaths.isEmpty ? nil : coordinator?.menu()
    }
}

/// One cell: the thumbnail (with edits applied), the file name and an "edited" mark.
final class PhotoGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")
    static let labelHeight: CGFloat = 22

    private let thumb = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let badge = NSImageView()
    private let selectionLayer = CALayer()
    private var loadTask: Task<Void, Never>?
    private var currentURL: URL?

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        selectionLayer.cornerRadius = 8
        root.layer?.addSublayer(selectionLayer)

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.shadowOpacity = 0.25
        thumb.layer?.shadowRadius = 2
        thumb.layer?.shadowOffset = CGSize(width: 0, height: -1)
        thumb.translatesAutoresizingMaskIntoConstraints = false

        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        badge.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Edited")
        badge.contentTintColor = .white
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        badge.layer?.cornerRadius = 9
        badge.imageScaling = .scaleProportionallyDown
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.toolTip = "Edited"

        root.addSubview(thumb)
        root.addSubview(label)
        root.addSubview(badge)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            thumb.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            thumb.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            thumb.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            label.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -3),
            label.heightAnchor.constraint(equalToConstant: 16),
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            badge.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -6),
        ])
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        selectionLayer.frame = view.bounds
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection
        selectionLayer.backgroundColor = on ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil
        label.textColor = on ? .labelColor : .secondaryLabelColor
        view.setAccessibilitySelected(on)
    }

    func configure(photo: ScannedPhoto, recipe: EditRecipe?, store: ThumbnailStore, pointSize: CGFloat) {
        label.stringValue = photo.name
        badge.isHidden = recipe == nil
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(recipe == nil ? photo.name : "\(photo.name), edited")

        let pixels = Int(pointSize * (view.window?.backingScaleFactor ?? 2))
        if currentURL != photo.url { thumb.image = nil }
        currentURL = photo.url
        loadTask?.cancel()
        if let cached = store.cachedThumbnail(for: photo, recipe: recipe, maxPixelSize: pixels) {
            thumb.image = NSImage(cgImage: cached, size: .zero)
            return
        }
        loadTask = Task { [weak self] in
            let image = await store.thumbnail(for: photo, recipe: recipe, maxPixelSize: pixels)
            guard let self, !Task.isCancelled, self.currentURL == photo.url, let image else { return }
            self.thumb.image = NSImage(cgImage: image, size: .zero)
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        thumb.image = nil
        currentURL = nil
    }
}
