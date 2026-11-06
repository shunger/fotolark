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
    enum Tool { case none, crop, straighten, whiteBalance }

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

    var tool: Tool = .none { didSet { if tool != oldValue { scheduleRender() } } }
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

    private let engine: EditEngine
    private let store: RecipeStore
    private var proxy: SendableImage?
    private var full: SendableImage?
    private var isLoadingFull = false
    private var pendingLabel: String?
    private var commitTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var isRendering = false
    private var needsRender = false

    init(url: URL, engine: EditEngine, store: RecipeStore) throws {
        self.url = url
        self.engine = engine
        self.store = store
        info = try ImageLoader.info(for: url)
        let saved = store.load(for: url) ?? EditRecipe()
        history = EditHistory(initial: saved, label: saved.isEmpty ? "Original" : "Saved edits")
        recipe = saved
        loadPreview()
    }

    // MARK: What's on screen

    /// The recipe drawn on the canvas: the original while comparing, and the uncropped
    /// photo while cropping.
    var shownRecipe: EditRecipe {
        if showOriginal { return EditRecipe() }
        var r = recipe.withoutResize
        if tool == .crop { r = r.removing(.crop) }
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
