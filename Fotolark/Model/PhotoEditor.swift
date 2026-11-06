import CoreImage
import FotolarkKit
import Observation
import SwiftUI

/// Wraps a CIImage so it can be handed to a background render. CIImage is immutable,
/// so sharing it between threads is safe.
struct SendableImage: @unchecked Sendable {
    let image: CIImage
}

/// Edits one photo: holds its recipe and undo history, renders the on-screen preview,
/// and saves the recipe to the sidecar file.
@MainActor @Observable
final class PhotoEditor {
    enum Tool { case none, crop, straighten, whiteBalance, redEye, retouch, focus, text, local, tiltShift, markup }

    /// Longest side of the copy used while editing; full resolution is loaded only for
    /// close-up zoom and export.
    nonisolated static let previewLongestSide = 2560

    let url: URL
    let info: PhotoInfo

    private(set) var history: EditHistory
    /// The recipe on screen. It runs ahead of `history` while a slider is moving.
    private(set) var recipe: EditRecipe
    private(set) var preview: CGImage?
    private(set) var previewIsFullResolution = false
    /// Histogram of what's on screen.
    private(set) var histogram: Histogram?
    /// Shown in the panel when a white balance click couldn't be used.
    var whiteBalanceMessage: String?
    /// Result of the last automatic fix that might not find anything (horizon, subject, red eyes).
    var toolMessage: String?

    var tool: Tool = .none {
        didSet {
            guard tool != oldValue else { return }
            toolMessage = nil
            scheduleRender()
        }
    }
    var showOriginal = false { didSet { if showOriginal != oldValue { scheduleRender() } } }
    /// Set by the canvas: how many pixels across the photo is drawn on screen.
    var displayPixelsNeeded = 0 { didSet { if needsFullResolution != previewIsFullResolution { scheduleRender() } } }
    var isBusy = false
    /// Called after the recipe is saved, so thumbnails can show the edit.
    var onSave: ((URL, EditRecipe) -> Void)?

    // Crop tool state
    var cropDraft = CropRect.full
    var cropAspect = CropAspect.free { didSet { applyAspectToDraft() } }
    var cropPortrait = false { didSet { applyAspectToDraft() } }
    var customAspectWidth = 4.0 { didSet { applyAspectToDraft() } }
    var customAspectHeight = 3.0 { didSet { applyAspectToDraft() } }

    let engine: EditEngine
    private let store: RecipeStore
    private var proxy: SendableImage?
    /// The working copy used for previews and one-click analysis.
    var proxyImage: CIImage? { proxy?.image }
    private var full: SendableImage?
    private var isLoadingFull = false
    private var pendingLabel: String?
    private var commitTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var isRendering = false
    private var needsRender = false

    /// `previous` is this photo's history from earlier in the session; it's picked up
    /// again when the saved edits still match where it left off.
    init(url: URL, engine: EditEngine, store: RecipeStore, previous: EditHistory? = nil) throws {
        self.url = url
        self.engine = engine
        self.store = store
        info = try ImageLoader.info(for: url)
        let record = store.loadRecord(for: url)
        let saved = record.recipe
        versions = record.versions
        if let previous, previous.current == saved {
            history = previous
        } else {
            history = EditHistory(initial: saved, label: saved.isEmpty ? "Original" : "Saved edits")
        }
        recipe = saved
        loadPreview()
    }

    // MARK: What's on screen

    /// The recipe drawn on the canvas: the original while comparing, and the uncropped
    /// photo while cropping.
    var shownRecipe: EditRecipe {
        if showOriginal { return EditRecipe() }
        var r = recipe.withoutResize
        // Tools work on the photo itself, so a border is hidden while one is open.
        if tool != .none { r = r.removing(.border) }
        // Captions and shapes sit on the cropped photo, so they're hidden while the crop changes.
        if tool == .crop { r = r.removing(.crop).removing(.text).removing(.markup) }
        return r
    }

    /// Full-resolution size of what's on the canvas.
    var shownSize: PixelSize {
        Geometry.outputSize(of: shownRecipe, source: info.pixelSize, includeResize: false)
    }

    /// Size of the photo after cropping and straightening, before any resize.
    var editedSize: PixelSize {
        Geometry.outputSize(of: recipe, source: info.pixelSize, includeResize: false)
    }

    /// Size an export will have.
    var outputSize: PixelSize { Geometry.outputSize(of: recipe, source: info.pixelSize) }

    var isLoaded: Bool { proxy != nil }
    var isEdited: Bool { !history.current.isEmpty }

    // MARK: Editing

    /// Shows `newRecipe` right away and records it in the history once the change settles
    /// (a slider is released, or input pauses).
    func setLive(_ newRecipe: EditRecipe, label: String) {
        if let pendingLabel, pendingLabel != label { commitPending() }
        recipe = newRecipe
        pendingLabel = label
        scheduleRender()
        commitTask?.cancel()
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.commitPending()
        }
    }

    /// Records the on-screen recipe in the history.
    func commitPending() {
        commitTask?.cancel()
        commitTask = nil
        guard let label = pendingLabel else { return }
        pendingLabel = nil
        if history.commit(recipe, label: label) { scheduleSave() }
    }

    /// Applies an edit and records it at once.
    func apply(_ newRecipe: EditRecipe, label: String) {
        commitPending()
        recipe = newRecipe
        if history.commit(newRecipe, label: label) { scheduleSave() }
        scheduleRender()
    }

    func undo() {
        commitPending()
        history.undo()
        restoreFromHistory()
    }

    func redo() {
        commitPending()
        history.redo()
        restoreFromHistory()
    }

    func jump(to id: EditHistory.Entry.ID) {
        commitPending()
        history.jump(to: id)
        restoreFromHistory()
    }

    private func restoreFromHistory() {
        recipe = history.current
        if tool == .crop { cropDraft = recipe.cropRect ?? .full }
        scheduleSave()
        scheduleRender()
    }

    func revertToOriginal() {
        tool = .none
        apply(EditRecipe(), label: "Revert to original")
    }

    // MARK: Sliders

    func adjustment(_ key: WritableKeyPath<Adjustments, Double>) -> Double {
        recipe.adjustments[keyPath: key]
    }

    func setAdjustment(_ key: WritableKeyPath<Adjustments, Double>, to value: Double, label: String) {
        var a = recipe.adjustments
        a[keyPath: key] = value
        setLive(recipe.settingAdjustments(a), label: label)
    }

    // MARK: One-click fixes

    func has(_ kind: EditOperation.Kind) -> Bool { recipe.operation(kind) != nil }

    /// Magic fix, Auto contrast and Auto color work as on/off switches.
    func toggleAutoFix(_ kind: EditOperation.Kind) {
        let label: String
        switch kind {
        case .magicFix: label = "Magic fix"
        case .autoContrast: label = "Auto contrast"
        default: label = "Auto color"
        }
        if has(kind) {
            apply(recipe.removing(kind), label: "Remove \(label.lowercased())")
            return
        }
        guard let proxy else { return }
        let before = SendableImage(image: RecipeRenderer.apply(recipe.prefix(before: kind), to: proxy.image))
        let engine = engine
        isBusy = true
        Task {
            let op = await Task.detached(priority: .userInitiated) { () -> EditOperation in
                switch kind {
                case .magicFix: engine.magicFix(for: before.image)
                case .autoContrast: engine.autoContrast(for: before.image)
                default: engine.autoColor(for: before.image)
                }
            }.value
            isBusy = false
            apply(recipe.setting(op), label: label)
        }
    }

    // MARK: White balance picker

    func beginWhiteBalance() {
        commitPending()
        whiteBalanceMessage = nil
        tool = .whiteBalance
    }

    /// Makes the spot clicked (normalized, top-left origin) neutral gray.
    func pickWhiteBalance(at point: CGPoint) {
        guard let proxy else { return }
        let sample = SendableImage(image: EditEngine.whiteBalanceSamplingImage(recipe, source: proxy.image))
        let engine = engine
        Task {
            let gains = await Task.detached(priority: .userInitiated) {
                engine.neutralGains(in: sample.image, at: point)
            }.value
            guard let gains else {
                whiteBalanceMessage = "That spot is too dark or too bright. Click something light gray or white, like a cloud, a wall or a shirt."
                return
            }
            whiteBalanceMessage = nil
            tool = .none
            apply(recipe.setting(.whiteBalance(gains)), label: "White balance")
        }
    }

    // MARK: Auto-straighten and auto-crop

    func autoStraighten() {
        guard let proxy else { return }
        let turned = SendableImage(image: RecipeRenderer.apply(
            EditRecipe(operations: recipe.operations.filter { $0.kind == .orient }), to: proxy.image))
        let engine = engine
        isBusy = true
        Task {
            let degrees = await Task.detached(priority: .userInitiated) { engine.horizonStraightening(for: turned.image) }.value
            isBusy = false
            if let degrees {
                toolMessage = String(format: "Straightened by %+.1f°.", degrees)
                apply(recipe.setting(.straighten(degrees: degrees)), label: "Auto-straighten")
            } else {
                toolMessage = "Fotolark couldn’t find a clear horizon in this photo. Use the slider instead."
            }
        }
    }

    /// Suggests a crop around the main subject (while the crop tool is open).
    func suggestCrop() {
        guard let proxy else { return }
        let uncropped = SendableImage(image: RecipeRenderer.apply(recipe.removing(.crop).withoutResize, to: proxy.image))
        let engine = engine
        isBusy = true
        Task {
            let crop = await Task.detached(priority: .userInitiated) { engine.suggestedCrop(for: uncropped.image) }.value
            isBusy = false
            if let crop {
                cropAspect = .free
                cropDraft = crop
                toolMessage = "Suggested a crop around the main subject. Adjust it or press Apply."
            } else {
                toolMessage = "The subject already fills the photo, so there's nothing to crop."
            }
        }
    }

    // MARK: Versions and markup

    /// Named versions of this photo's edits.
    private(set) var versions: [EditVersion] = []
    var markupKind = MarkupShape.Kind.arrow
    var markupColor = RGBAColor(red: 0.95, green: 0.15, blue: 0.1)
    var markupWidth = 0.006
    var selectedShapeID: UUID?

    func setVersions(_ list: [EditVersion]) {
        versions = list
        let store = store, url = url
        Task.detached(priority: .userInitiated) { _ = try? store.update(url) { $0.versions = list } }
    }

    // MARK: Brush and gradient adjustments

    /// The brush or gradient being worked on.
    var selectedLocalID: UUID?
    /// Brush strokes take the effect away instead of adding it.
    var localErase = false

    // MARK: Retouching

    var retouchTool = RetouchStroke.Tool.heal { didSet { toolMessage = nil } }
    /// Brush radius in screen points.
    var brushSize = 20.0
    var softenStrength = 0.7
    /// Where Clone copies from (a point on the original photo).
    var cloneSource: CGPoint?

    var retouchStrokes: [RetouchStroke] {
        if case .retouch(let strokes) = recipe.operation(.retouch) { return strokes }
        return []
    }

    func beginRetouch() {
        commitPending()
        tool = .retouch
    }

    /// Sets where Clone copies from (⌥-click), from a point on the photo as shown.
    func setCloneSource(atDisplayPoint p: CGPoint) {
        cloneSource = PointMapping.sourcePoint(fromDisplay: p, recipe: shownRecipe, sourceSize: info.pixelSize)
        toolMessage = "Now paint where you want to copy to."
    }

    /// Where the clone source is on screen.
    var cloneSourceDisplayPoint: CGPoint? {
        cloneSource.flatMap { PointMapping.displayPoint(fromSource: $0, recipe: shownRecipe, sourceSize: info.pixelSize) }
    }

    /// Adds a stroke painted on screen. `points` are normalized to the shown photo and
    /// `radiusFraction` is the brush radius as a fraction of the shown photo's longest side.
    func addStroke(displayPoints points: [CGPoint], radiusFraction: Double) {
        guard !points.isEmpty else { return }
        let source = points.map { PointMapping.sourcePoint(fromDisplay: $0, recipe: shownRecipe, sourceSize: info.pixelSize) }
        let shownLongest = Double(max(shownSize.width, shownSize.height))
        let sourceLongest = Double(max(info.pixelSize.width, info.pixelSize.height))
        let radius = radiusFraction * shownLongest / sourceLongest
        let curvePoints = source.map { CurvePoint($0.x, $0.y) }

        switch retouchTool {
        case .clone:
            guard let from = cloneSource else {
                toolMessage = "First ⌥-click (Option-click) the spot to copy from."
                return
            }
            let offset = CurvePoint(from.x - source[0].x, from.y - source[0].y)
            appendStroke(RetouchStroke(tool: .clone, points: curvePoints, radius: radius, sourceOffset: offset), label: "Clone")
        case .soften:
            appendStroke(RetouchStroke(tool: .soften, points: curvePoints, radius: radius, strength: softenStrength),
                         label: "Soften skin")
        case .heal, .remove:
            let tool = retouchTool
            guard let proxy else { return }
            // Pick the source for the middle of the stroke, far enough to clear all of it.
            let xs = source.map(\.x), ys = source.map(\.y)
            let center = CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
            let aspect = Double(info.pixelSize.width) / Double(max(info.pixelSize.height, 1))
            let spanX = (xs.max()! - xs.min()!) * (aspect >= 1 ? 1 : aspect)
            let spanY = (ys.max()! - ys.min()!) * (aspect >= 1 ? 1 / aspect : 1)
            let reach = radius + max(spanX, spanY) / 2
            let image = SendableImage(image: RecipeRenderer.apply(recipe.prefix(before: .adjust), to: proxy.image))
            let engine = engine
            isBusy = true
            Task {
                let offset = await Task.detached(priority: .userInitiated) {
                    engine.healSourceOffset(for: center, radius: reach, in: image.image)
                }.value
                isBusy = false
                appendStroke(RetouchStroke(tool: tool, points: curvePoints, radius: radius, sourceOffset: offset),
                             label: tool == .remove ? "Remove object" : "Spot heal")
            }
        }
    }

    private func appendStroke(_ stroke: RetouchStroke, label: String) {
        apply(recipe.setting(.retouch(retouchStrokes + [stroke])), label: label)
    }

    func undoLastStroke() {
        var strokes = retouchStrokes
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        apply(recipe.setting(.retouch(strokes)), label: "Remove stroke")
    }

    // MARK: Looks

    /// Small previews of each look on this photo, for the Effects panel.
    private(set) var lookPreviews: [Look.Kind: CGImage] = [:]
    private var lookPreviewTask: Task<Void, Never>?

    func refreshLookPreviews() {
        guard let proxy else { return }
        lookPreviewTask?.cancel()
        let base = recipe.removing(.looks).withoutResize
        let engine = engine
        lookPreviewTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let previews = await Task.detached(priority: .utility) { () -> [Look.Kind: CGImage] in
                let s = 140 / max(proxy.image.extent.width, proxy.image.extent.height)
                let small = proxy.image.transformed(by: CGAffineTransform(scaleX: s, y: s)).normalizedForPreview()
                let edited = RecipeRenderer.apply(base, to: small, includeResize: false)
                var out: [Look.Kind: CGImage] = [:]
                for kind in Look.Kind.allCases {
                    if let cg = engine.makeCGImage(RecipeRenderer.apply(.looks([Look(kind: kind)]), to: edited)) { out[kind] = cg }
                }
                return out
            }.value
            guard !Task.isCancelled else { return }
            lookPreviews = previews
        }
    }

    func addLook(_ kind: Look.Kind) {
        apply(recipe.setting(.looks(recipe.looks + [Look(kind: kind)])), label: kind.title)
        if kind == .focalBW {
            tool = .focus
            toolMessage = "Click the part of the photo to keep in color."
        }
    }

    func updateLook(_ look: Look, live: Bool = true) {
        let looks = recipe.looks.map { $0.id == look.id ? look : $0 }
        if live { setLive(recipe.setting(.looks(looks)), label: look.kind.title) } else { apply(recipe.setting(.looks(looks)), label: look.kind.title) }
    }

    func removeLook(_ look: Look) {
        apply(recipe.setting(.looks(recipe.looks.filter { $0.id != look.id })), label: "Remove \(look.kind.title.lowercased())")
    }

    /// Sets the focus point of the (last) focal B&W look from a click.
    func setFocus(atDisplayPoint p: CGPoint) {
        guard var look = recipe.looks.last(where: { $0.kind == .focalBW }) else { return }
        let s = PointMapping.sourcePoint(fromDisplay: p, recipe: shownRecipe, sourceSize: info.pixelSize)
        look.focusX = s.x
        look.focusY = s.y
        updateLook(look, live: false)
    }

    var focusDisplay: (point: CGPoint, radius: Double)? {
        guard let look = recipe.looks.last(where: { $0.kind == .focalBW }),
              let p = PointMapping.displayPoint(fromSource: CGPoint(x: look.focusX, y: look.focusY), recipe: shownRecipe,
                                                sourceSize: info.pixelSize) else { return nil }
        let r = look.focusRadius * Double(max(info.pixelSize.width, info.pixelSize.height)) / Double(max(shownSize.width, shownSize.height))
        return (p, r)
    }

    // MARK: Text

    var selectedTextID: UUID?

    var textOverlays: [TextOverlay] { recipe.textOverlays }

    func addText(atDisplayPoint p: CGPoint) {
        let overlay = TextOverlay(text: "Your text", x: p.x, y: p.y)
        selectedTextID = overlay.id
        apply(recipe.setting(.text(textOverlays + [overlay])), label: "Add text")
    }

    func updateText(_ overlay: TextOverlay, live: Bool = true) {
        let list = textOverlays.map { $0.id == overlay.id ? overlay : $0 }
        if live { setLive(recipe.setting(.text(list)), label: "Text") } else { apply(recipe.setting(.text(list)), label: "Text") }
    }

    func deleteSelectedText() {
        guard let id = selectedTextID else { return }
        selectedTextID = nil
        apply(recipe.setting(.text(textOverlays.filter { $0.id != id })), label: "Delete text")
    }

    // MARK: Red eye

    /// Opens the red-eye tool and fixes any red eyes Vision can find.
    func beginRedEye() {
        commitPending()
        tool = .redEye
        toolMessage = "Looking for red eyes…"
        guard let proxy else { return }
        let source = SendableImage(image: RecipeRenderer.apply(recipe.prefix(before: .redEye), to: proxy.image))
        let engine = engine
        Task {
            let found = await Task.detached(priority: .userInitiated) { engine.detectRedEyes(in: source.image) }.value
            guard tool == .redEye else { return }
            if found.isEmpty {
                toolMessage = "No red eyes found. Click any red eye in the photo to fix it."
            } else {
                apply(recipe.setting(.redEye(redEyeSpots + found)), label: "Red-eye")
                toolMessage = "Fixed \(found.count) red \(found.count == 1 ? "eye" : "eyes"). Click any others to fix them too."
            }
        }
    }

    var redEyeSpots: [EyeSpot] {
        if case .redEye(let spots) = recipe.operation(.redEye) { return spots }
        return []
    }

    /// Fixes a red eye where the person clicked (a point on the photo as shown).
    func addRedEye(atDisplayPoint point: CGPoint) {
        let source = PointMapping.sourcePoint(fromDisplay: point, recipe: shownRecipe, sourceSize: info.pixelSize)
        let spot = EyeSpot(x: source.x, y: source.y, radius: 0.012)
        apply(recipe.setting(.redEye(redEyeSpots + [spot])), label: "Red-eye")
    }

    /// Where the fixed eyes are on screen, for drawing circles around them.
    var redEyeDisplaySpots: [(center: CGPoint, radius: Double)] {
        let shown = shownSize
        let source = info.pixelSize
        return redEyeSpots.compactMap { spot in
            guard let p = PointMapping.displayPoint(fromSource: CGPoint(x: spot.x, y: spot.y), recipe: shownRecipe,
                                                    sourceSize: source) else { return nil }
            // Radius as a fraction of the shown photo's longest side.
            let r = spot.radius * Double(max(source.width, source.height)) / Double(max(shown.width, shown.height))
            return (p, r)
        }
    }

    // MARK: Copy and paste

    /// Pastes copied tone and color edits, working the one-click fixes out for this photo.
    func paste(_ copied: EditRecipe) {
        guard let proxy else { return }
        let target = recipe.pasting(copied)
        let engine = engine
        isBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                engine.recomputingAutoFixes(target, for: proxy.image)
            }.value
            isBusy = false
            apply(result, label: "Paste edits")
        }
    }

    // MARK: Geometry

    func rotate(clockwise: Bool) {
        apply(recipe.rotated(clockwise: clockwise), label: clockwise ? "Rotate right" : "Rotate left")
        if tool == .crop { cropDraft = clockwise ? cropDraft.rotatedClockwise() : cropDraft.rotatedCounterclockwise() }
    }

    func flip(horizontally: Bool) {
        apply(recipe.flipped(horizontally: horizontally), label: horizontally ? "Flip horizontal" : "Flip vertical")
        if tool == .crop { cropDraft = horizontally ? cropDraft.flippedHorizontally() : cropDraft.flippedVertically() }
    }

    func setStraighten(_ degrees: Double) {
        setLive(recipe.setting(.straighten(degrees: (degrees * 10).rounded() / 10)), label: "Straighten")
    }

    func setResize(_ spec: ResizeSpec?) {
        if let spec, PixelSize(width: spec.width, height: spec.height) != editedSize || spec.dpi != nil {
            apply(recipe.setting(.resize(spec)), label: "Resize")
        } else {
            apply(recipe.removing(.resize), label: "Original size")
        }
    }

    // MARK: Crop tool

    func beginCrop() {
        commitPending()
        cropDraft = recipe.cropRect ?? .full
        cropAspect = .free
        // Print shapes start out matching the photo: tall for a portrait photo.
        cropPortrait = uncroppedAspect < 1
        tool = .crop
    }

    func applyCrop() {
        tool = .none
        apply(recipe.setting(.crop(cropDraft.clamped())), label: "Crop")
    }

    func cancelCrop() {
        tool = .none
    }

    /// Width ÷ height of the uncropped photo, in pixels.
    var uncroppedAspect: Double {
        Geometry.outputSize(of: recipe.removing(.crop).withoutResize, source: info.pixelSize).aspectRatio
    }

    /// The chosen crop shape as width ÷ height in normalized (0…1) units, or nil for free.
    var normalizedCropAspect: Double? {
        guard let ratio = cropAspect.ratio(original: uncroppedAspect, customWidth: customAspectWidth,
                                           customHeight: customAspectHeight) else { return nil }
        let pixelRatio = cropPortrait ? 1 / ratio : ratio
        return pixelRatio / uncroppedAspect
    }

    /// Fits the largest rectangle of the chosen shape inside the current crop, centered.
    private func applyAspectToDraft() {
        guard tool == .crop, let a = normalizedCropAspect else { return }
        let c = cropDraft
        var w = c.width, h = c.height
        if w / h > a { w = h * a } else { h = w / a }
        cropDraft = CropRect(x: c.x + (c.width - w) / 2, y: c.y + (c.height - h) / 2, width: w, height: h)
    }

    // MARK: Rendering

    private var needsFullResolution: Bool {
        guard let proxy else { return false }
        let proxyLongest = max(proxy.image.extent.width, proxy.image.extent.height)
        let fullLongest = CGFloat(max(info.pixelSize.width, info.pixelSize.height))
        let shownLongest = CGFloat(max(shownSize.width, shownSize.height))
        // How many proxy pixels the shown area has, compared with what the screen needs.
        let available = shownLongest * proxyLongest / fullLongest
        return fullLongest > proxyLongest * 1.05 && CGFloat(displayPixelsNeeded) > available * 1.1
    }

    private func loadPreview() {
        let url = url
        Task {
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    SendableImage(image: try ImageLoader.loadPreview(url, maxPixelSize: Self.previewLongestSide))
                }.value
                proxy = image
                scheduleRender()
                refreshLookPreviews()
            } catch {
                AppModel.shared.errorMessage = error.localizedDescription
            }
        }
    }

    private func loadFullResolution() {
        guard full == nil, !isLoadingFull else { return }
        isLoadingFull = true
        let url = url
        Task {
            full = try? await Task.detached(priority: .utility) {
                SendableImage(image: try ImageLoader.loadFull(url))
            }.value
            isLoadingFull = false
            scheduleRender()
        }
    }

    /// Renders the latest state. Renders never queue up: while one is running, further
    /// changes just mark the preview stale, and one more render runs at the end.
    func scheduleRender() {
        needsRender = true
        guard !isRendering, proxy != nil else { return }
        isRendering = true
        Task { await renderLoop() }
    }

    private func renderLoop() async {
        while needsRender, let proxy {
            needsRender = false
            let wantFull = needsFullResolution && pendingLabel == nil
            if wantFull && full == nil { loadFullResolution() }
            let source = (wantFull ? full : nil) ?? proxy
            let usingFull = wantFull && full != nil
            let shown = shownRecipe
            let engine = engine
            let (image, histogram) = await Task.detached(priority: .userInitiated) {
                (engine.render(shown, source: source.image, includeResize: false),
                 engine.histogram(of: RecipeRenderer.apply(shown, to: proxy.image, includeResize: false)))
            }.value
            preview = image
            self.histogram = histogram
            previewIsFullResolution = usingFull
        }
        isRendering = false
    }

    // MARK: Saving

    private func scheduleSave() {
        refreshLookPreviews()
        saveTask?.cancel()
        let recipe = history.current
        let url = url
        let store = store
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                _ = try? store.save(recipe, for: url)
            }.value
            self?.onSave?(url, recipe)
        }
    }

    /// Saves right away, e.g. before moving to another photo or quitting.
    func saveNow() {
        commitPending()
        saveTask?.cancel()
        saveTask = nil
        _ = try? store.save(history.current, for: url)
        onSave?(url, history.current)
    }

    // MARK: Export

    func export(options: ExportOptions, to destination: URL) async throws {
        commitPending()
        let url = url
        let recipe = history.current
        let engine = engine
        isBusy = true
        defer { isBusy = false }
        try await Task.detached(priority: .userInitiated) {
            try ImageExporter.export(source: url, recipe: recipe, options: options, to: destination, engine: engine)
        }.value
    }
}

/// Crop shapes offered in the crop tool. Ratios are given landscape (width ≥ height);
/// the portrait switch turns them.
enum CropAspect: String, CaseIterable, Identifiable {
    case free, original, square, r4x3, r3x2, r16x9, r5x7, r8x10, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "Square (1:1)"
        case .r4x3: "4:3"
        case .r3x2: "3:2 (4 × 6 print)"
        case .r16x9: "16:9 (widescreen)"
        case .r5x7: "5 × 7 print"
        case .r8x10: "8 × 10 print"
        case .custom: "Custom"
        }
    }

    func ratio(original: Double, customWidth: Double, customHeight: Double) -> Double? {
        switch self {
        case .free: nil
        case .original: max(original, 1 / original)
        case .square: 1
        case .r4x3: 4.0 / 3
        case .r3x2: 3.0 / 2
        case .r16x9: 16.0 / 9
        case .r5x7: 7.0 / 5
        case .r8x10: 10.0 / 8
        case .custom: customHeight > 0 && customWidth > 0 ? customWidth / customHeight : nil
        }
    }
}

extension CIImage {
    /// Moves the image so it starts at (0, 0), as the editing engine expects.
    func normalizedForPreview() -> CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}
