import AppKit
import FotolarkKit
import SwiftUI

/// The thumbnail grid. Built on NSCollectionView, which reuses cells so folders with
/// tens of thousands of photos scroll smoothly, and brings native selection, arrow-key
/// navigation, rubber-band selection and dragging to Finder or Mail.
struct PhotoGridView: NSViewRepresentable {
    let photos: [ScannedPhoto]
    let recipes: [URL: EditRecipe]
    var labels: [URL: PhotoLabels] = [:]
    /// File names under every photo (otherwise on hover).
    var showNames = false
    /// Thumbnails cropped to even squares.
    var squareThumbnails = false
    /// Titled groups (the timeline's months); nil shows one plain grid.
    var sections: [GridSection]? = nil
    @Binding var selection: Set<URL>
    let thumbnailSize: CGFloat
    let thumbnails: ThumbnailStore
    let promises: EditedPhotoPromise
    let onOpen: (URL) -> Void
    let makeMenu: () -> NSMenu
    /// Number keys rate, P picks, X rejects, U clears the flag.
    var onLabel: (LabelChange) -> Void = { _ in }

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
        collection.register(GridSectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: GridSectionHeader.identifier)
        layout.sectionHeadersPinToVisibleBounds = true
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
        private var dataSource: NSCollectionViewDiffableDataSource<String, URL>?
        private weak var collection: NSCollectionView?
        private var byURL: [URL: ScannedPhoto] = [:]
        private var shownURLs: [URL] = []
        private var shownSections: [GridSection]?
        private var sectionTitles: [String: String] = [:]
        private var shownRecipes: [URL: EditRecipe] = [:]
        private var shownLabels: [URL: PhotoLabels] = [:]
        private var itemSize: CGFloat = 0
        private var shownStyle: [Bool] = []
        private var isApplyingSelection = false

        init(_ parent: PhotoGridView) { self.parent = parent }

        func attach(_ collection: NSCollectionView) {
            self.collection = collection
            dataSource = NSCollectionViewDiffableDataSource<String, URL>(collectionView: collection) {
                [weak self] collectionView, indexPath, url in
                let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath)
                if let self, let cell = item as? PhotoGridItem, let photo = self.byURL[url] {
                    cell.configure(photo: photo, recipe: self.parent.recipes[url], labels: self.parent.labels[url],
                                   store: self.parent.thumbnails, pointSize: self.itemSize,
                                   showNames: self.parent.showNames, square: self.parent.squareThumbnails)
                }
                return item
            }
            dataSource?.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
                let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: GridSectionHeader.identifier,
                                                                for: indexPath)
                if let header = view as? GridSectionHeader, let self,
                   let id = self.dataSource?.snapshot().sectionIdentifiers[safe: indexPath.section] {
                    let count = self.dataSource?.snapshot().numberOfItems(inSection: id) ?? 0
                    header.set(title: self.sectionTitles[id] ?? "", count: count)
                }
                return view as! (NSView & NSCollectionViewElement)
            }
        }

        func update(with parent: PhotoGridView) {
            self.parent = parent
            guard let collection, let dataSource else { return }

            if itemSize != parent.thumbnailSize || shownStyle != [parent.showNames, parent.squareThumbnails] {
                itemSize = parent.thumbnailSize
                shownStyle = [parent.showNames, parent.squareThumbnails]
                collection.collectionViewLayout?.invalidateLayout()
                refreshVisible()
            }

            let urls = parent.photos.map(\.url)
            byURL = Dictionary(parent.photos.map { ($0.url, $0) }, uniquingKeysWith: { a, _ in a })
            if urls != shownURLs || parent.sections != shownSections {
                shownURLs = urls
                shownSections = parent.sections
                var snapshot = NSDiffableDataSourceSnapshot<String, URL>()
                if let sections = parent.sections {
                    sectionTitles = Dictionary(sections.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
                    for section in sections {
                        snapshot.appendSections([section.id])
                        snapshot.appendItems(section.urls, toSection: section.id)
                    }
                } else {
                    sectionTitles = [:]
                    snapshot.appendSections([""])
                    snapshot.appendItems(urls)
                }
                (collection.collectionViewLayout as? NSCollectionViewFlowLayout)?.headerReferenceSize =
                    parent.sections == nil ? .zero : NSSize(width: 0, height: GridSectionHeader.height)
                dataSource.apply(snapshot, animatingDifferences: false)
            }

            // Thumbnails whose edits, rating, flag or tags changed.
            var changed: Set<URL> = []
            if parent.recipes != shownRecipes {
                changed.formUnion(Set(parent.recipes.keys).union(shownRecipes.keys).filter { parent.recipes[$0] != shownRecipes[$0] })
                shownRecipes = parent.recipes
            }
            if parent.labels != shownLabels {
                changed.formUnion(Set(parent.labels.keys).union(shownLabels.keys).filter { parent.labels[$0] != shownLabels[$0] })
                shownLabels = parent.labels
            }
            if !changed.isEmpty { refreshVisible(only: changed) }

            applySelection(parent.selection)
        }

        private func refreshVisible(only urls: Set<URL>? = nil) {
            guard let collection, let dataSource else { return }
            for indexPath in collection.indexPathsForVisibleItems() {
                guard let url = dataSource.itemIdentifier(for: indexPath), urls?.contains(url) ?? true,
                      let photo = byURL[url],
                      let cell = collection.item(at: indexPath) as? PhotoGridItem else { continue }
                cell.configure(photo: photo, recipe: parent.recipes[url], labels: parent.labels[url],
                               store: parent.thumbnails, pointSize: itemSize,
                               showNames: parent.showNames, square: parent.squareThumbnails)
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
            NSSize(width: itemSize, height: itemSize + (parent.showNames ? PhotoGridItem.labelHeight : 0))
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                            forRepresentedObjectAt indexPath: IndexPath) {
            (item as? PhotoGridItem)?.cancelLoading()
        }

        // Dragging a photo out copies the file (to Finder, Mail, Messages…).
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let url = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            if let recipe = parent.recipes[url], !recipe.isEmpty {
                return parent.promises.provider(for: url, recipe: recipe)
            }
            return url as NSURL
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

        func label(_ change: LabelChange) { parent.onLabel(change) }
    }
}

/// A month heading in the timeline; stays at the top while its photos scroll by.
final class GridSectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("GridSectionHeader")
    static let height: CGFloat = 36

    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        count.font = .systemFont(ofSize: 12)
        count.textColor = .secondaryLabelColor
        count.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        addSubview(title)
        addSubview(count)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(title text: String, count n: Int) {
        title.stringValue = text
        count.stringValue = n == 1 ? "1 photo" : "\(n.formatted()) photos"
        setAccessibilityLabel("\(text), \(count.stringValue)")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
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
        } else if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, let change = LabelChange(key: chars) {
            coordinator?.label(change)
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

/// One cell: the thumbnail (with edits applied), small badges for stars, flag and
/// edits, and the file name (always, or only on hover).
final class PhotoGridItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoGridItem")
    static let labelHeight: CGFloat = 22

    private let photo = CALayer()
    private let shimmer = CAGradientLayer()
    private let label = NSTextField(labelWithString: "")
    private let hoverName = NSTextField(labelWithString: "")
    private let edited = Badge(symbol: "slider.horizontal.3", tint: .white, fill: NSColor.black.withAlphaComponent(0.55))
    private let stars = NSTextField(labelWithString: "")
    private let flag = Badge(symbol: "flag.fill", tint: .white, fill: .systemGreen)
    private let selectionLayer = CALayer()
    private var loadTask: Task<Void, Never>?
    private var currentURL: URL?
    private var showNames = false
    private var square = false
    private var hovering = false { didSet { updateHover() } }

    override func loadView() {
        let root = HoverView()
        root.wantsLayer = true
        root.onHover = { [weak self] in self?.hovering = $0 }

        selectionLayer.cornerRadius = 9
        root.layer?.addSublayer(selectionLayer)

        photo.cornerRadius = 4
        photo.masksToBounds = true
        photo.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        root.layer?.addSublayer(photo)

        // A soft light band sweeping across while the thumbnail loads.
        shimmer.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.18).cgColor,
                          NSColor.white.withAlphaComponent(0).cgColor]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [0, 0.5, 1]
        photo.addSublayer(shimmer)

        label.lineBreakMode = .byTruncatingMiddle
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor

        hoverName.lineBreakMode = .byTruncatingMiddle
        hoverName.alignment = .center
        hoverName.font = .systemFont(ofSize: 11, weight: .medium)
        hoverName.textColor = .white
        hoverName.wantsLayer = true
        hoverName.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        hoverName.layer?.cornerRadius = 4
        hoverName.isHidden = true

        stars.font = .systemFont(ofSize: 10, weight: .semibold)
        stars.textColor = .white
        stars.wantsLayer = true
        stars.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        stars.layer?.cornerRadius = 4
        stars.alignment = .center

        edited.toolTip = "Edited"
        for v in [label, edited, stars, flag, hoverName] as [NSView] { root.addSubview(v) }
        view = root
    }

    /// Where the photo sits in the cell.
    private var photoArea: CGRect {
        let b = view.bounds
        let bottom = showNames ? Self.labelHeight : 0
        return CGRect(x: 6, y: bottom + 6, width: b.width - 12, height: b.height - bottom - 12)
    }

    /// The picture itself inside that area (smaller than it when shown whole).
    private var pictureRect: CGRect {
        let area = photoArea
        guard !square, let image = photo.contents.map({ $0 as! CGImage }) else { return area }
        let a = CGFloat(image.width) / CGFloat(max(image.height, 1))
        var w = area.width, h = area.height
        if a > w / h { h = w / a } else { w = h * a }
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h).integral
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.frame = view.bounds.insetBy(dx: 1, dy: 1)
        photo.frame = pictureRect
        shimmer.frame = CGRect(x: -photo.bounds.width, y: 0, width: photo.bounds.width * 3, height: photo.bounds.height)
        CATransaction.commit()
        let pic = pictureRect
        label.frame = CGRect(x: 4, y: 3, width: view.bounds.width - 8, height: 16)
        label.isHidden = !showNames
        let starsWidth = stars.intrinsicContentSize.width + 10
        stars.frame = CGRect(x: pic.minX + 4, y: pic.minY + 4, width: min(starsWidth, pic.width - 8), height: 16)
        edited.frame = CGRect(x: pic.maxX - 22, y: pic.minY + 4, width: 18, height: 16)
        flag.frame = CGRect(x: pic.maxX - 22, y: pic.maxY - 20, width: 18, height: 16)
        hoverName.frame = CGRect(x: pic.minX + 4, y: pic.minY + 24, width: pic.width - 8, height: 16)
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    /// A rounded outline in the accent color; the photo itself isn't tinted.
    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection
        selectionLayer.borderWidth = on ? 3 : 0
        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        selectionLayer.backgroundColor = on ? NSColor.controlAccentColor.withAlphaComponent(0.1).cgColor : nil
        label.textColor = on ? .labelColor : .secondaryLabelColor
        view.setAccessibilitySelected(on)
    }

    private func updateHover() {
        hoverName.isHidden = showNames || !hovering
        view.layer?.backgroundColor = hovering ? NSColor.labelColor.withAlphaComponent(0.04).cgColor : nil
    }

    func configure(photo scanned: ScannedPhoto, recipe: EditRecipe?, labels: PhotoLabels?, store: ThumbnailStore,
                   pointSize: CGFloat, showNames: Bool, square: Bool) {
        self.showNames = showNames
        self.square = square
        photo.contentsGravity = square ? .resizeAspectFill : .resizeAspect
        label.stringValue = scanned.name
        hoverName.stringValue = scanned.name
        edited.isHidden = recipe == nil
        let l = labels ?? PhotoLabels()
        stars.isHidden = l.rating == 0
        stars.stringValue = String(repeating: "★", count: l.rating)
        switch l.flag {
        case .none:
            flag.isHidden = true
        case .pick:
            flag.isHidden = false
            flag.set(symbol: "flag.fill", fill: .systemGreen, description: "Pick")
        case .reject:
            flag.isHidden = false
            flag.set(symbol: "xmark", fill: .systemRed, description: "Rejected")
        }
        // Rejects fade back so the keepers stand out.
        photo.opacity = l.flag == .reject ? 0.4 : 1
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        var spoken = [scanned.name]
        if recipe != nil { spoken.append("edited") }
        if l.rating > 0 { spoken.append(l.rating == 1 ? "1 star" : "\(l.rating) stars") }
        if l.flag == .pick { spoken.append("pick") } else if l.flag == .reject { spoken.append("rejected") }
        if !l.tags.isEmpty { spoken.append("tags: " + l.tags.joined(separator: ", ")) }
        view.setAccessibilityLabel(spoken.joined(separator: ", "))
        view.toolTip = l.tags.isEmpty ? nil : l.tags.joined(separator: ", ")
        updateHover()

        let pixels = Int(pointSize * (view.window?.backingScaleFactor ?? 2))
        if currentURL != scanned.url { show(nil, animated: false) }
        currentURL = scanned.url
        loadTask?.cancel()
        if let cached = store.cachedThumbnail(for: scanned, recipe: recipe, maxPixelSize: pixels) {
            show(cached, animated: false)
            return
        }
        loadTask = Task { [weak self] in
            let image = await store.thumbnail(for: scanned, recipe: recipe, maxPixelSize: pixels)
            guard let self, !Task.isCancelled, self.currentURL == scanned.url, let image else { return }
            self.show(image, animated: true)
        }
        view.needsLayout = true
    }

    /// Puts the thumbnail in (fading in when it just arrived), or the loading shimmer.
    private func show(_ image: CGImage?, animated: Bool) {
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            photo.add(fade, forKey: "fade")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        photo.contents = image
        photo.backgroundColor = image == nil ? NSColor.quaternaryLabelColor.cgColor : nil
        CATransaction.commit()
        if image == nil {
            shimmer.isHidden = false
            if shimmer.animation(forKey: "sweep") == nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let sweep = CABasicAnimation(keyPath: "transform.translation.x")
                sweep.fromValue = -photo.bounds.width
                sweep.toValue = photo.bounds.width
                sweep.duration = 1.3
                sweep.repeatCount = .infinity
                shimmer.add(sweep, forKey: "sweep")
            }
        } else {
            shimmer.removeAllAnimations()
            shimmer.isHidden = true
        }
        view.needsLayout = true
    }

    func cancelLoading() {
        loadTask?.cancel()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        show(nil, animated: false)
        currentURL = nil
        hovering = false
    }
}

/// A small rounded badge with a symbol (edited, pick, reject).
final class Badge: NSView {
    private let icon = NSImageView()

    init(symbol: String, tint: NSColor, fill: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = fill.cgColor
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyDown
        icon.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        addSubview(icon)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(symbol: String, fill: NSColor, description: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        layer?.backgroundColor = fill.cgColor
    }

    override func layout() {
        super.layout()
        icon.frame = bounds.insetBy(dx: 3, dy: 2)
    }
}

/// Reports the pointer entering and leaving (for showing the name on hover).
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
