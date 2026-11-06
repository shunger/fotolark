import CoreGraphics
import FotolarkKit
import Foundation

/// Brush and gradient adjustments, tilt-shift and lens correction.
extension PhotoEditor {
    // MARK: Points

    /// A point on the shown photo (normalized) as a point on the original.
    func sourceCurvePoint(_ display: CGPoint) -> CurvePoint {
        let p = PointMapping.sourcePoint(fromDisplay: display, recipe: shownRecipe, sourceSize: info.pixelSize)
        return CurvePoint(p.x, p.y)
    }

    /// A point on the original as a point on the shown photo; nil if it's cropped away.
    func displayPoint(_ source: CurvePoint) -> CGPoint? {
        PointMapping.displayPoint(fromSource: CGPoint(x: source.x, y: source.y), recipe: shownRecipe,
                                  sourceSize: info.pixelSize)
    }

    /// Like `displayPoint`, but also for points outside the crop (for handles near the edge).
    func displayPointUnclamped(_ source: CurvePoint) -> CGPoint {
        // Map a point a little way toward the center and extend, if the point itself is cropped away.
        if let p = displayPoint(source) { return p }
        let c = sourceCurvePoint(CGPoint(x: 0.5, y: 0.5))
        for t in stride(from: 0.9, to: 0.0, by: -0.1) {
            let q = CurvePoint(c.x + (source.x - c.x) * t, c.y + (source.y - c.y) * t)
            if let d = displayPoint(q) {
                return CGPoint(x: 0.5 + (d.x - 0.5) / t, y: 0.5 + (d.y - 0.5) / t)
            }
        }
        return CGPoint(x: 0.5, y: 0.5)
    }

    /// Shown-photo pixels per original-photo pixel.
    var displayToSourceScale: Double {
        Double(max(info.pixelSize.width, info.pixelSize.height)) / Double(max(shownSize.width, shownSize.height))
    }

    // MARK: Brush and gradient

    var localAdjustments: [LocalAdjustment] { recipe.localAdjustments }

    var selectedLocal: LocalAdjustment? {
        localAdjustments.first { $0.id == selectedLocalID }
    }

    func beginLocal(_ kind: LocalAdjustment.Kind? = nil) {
        commitPending()
        tool = .local
        if let kind {
            addLocal(kind)
        } else if selectedLocal == nil {
            selectedLocalID = localAdjustments.last?.id
        }
    }

    func addLocal(_ kind: LocalAdjustment.Kind) {
        var adj = LocalAdjustment(kind: kind)
        switch kind {
        case .brush:
            adj.settings.exposure = 0.3
        case .gradient:
            // Darken the top of the photo, the usual sky fix.
            adj.settings.exposure = -0.3
            adj.start = sourceCurvePoint(CGPoint(x: 0.5, y: 0.0))
            adj.end = sourceCurvePoint(CGPoint(x: 0.5, y: 0.45))
        }
        localErase = false
        apply(recipe.setting(.local(localAdjustments + [adj])), label: kind == .brush ? "Add brush" : "Add gradient")
        selectedLocalID = adj.id
    }

    func updateLocal(_ adj: LocalAdjustment, live: Bool = true, label: String = "Adjust") {
        var list = localAdjustments
        guard let i = list.firstIndex(where: { $0.id == adj.id }) else { return }
        list[i] = adj
        let r = recipe.setting(.local(list))
        if live { setLive(r, label: label) } else { apply(r, label: label) }
    }

    func removeLocal(_ id: UUID) {
        let list = localAdjustments.filter { $0.id != id }
        apply(list.isEmpty ? recipe.removing(.local) : recipe.setting(.local(list)), label: "Remove adjustment")
        if selectedLocalID == id { selectedLocalID = list.last?.id }
    }

    /// Adds a painted stroke to the selected brush (or a new one).
    func addLocalStroke(displayPoints points: [CGPoint], radiusFraction: Double, erase: Bool) {
        guard !points.isEmpty else { return }
        if selectedLocal?.kind != .brush {
            if erase { return }
            addLocal(.brush)
        }
        guard var adj = selectedLocal else { return }
        let stroke = LocalAdjustment.Stroke(points: points.map(sourceCurvePoint),
                                            radius: radiusFraction / displayToSourceScale, erase: erase)
        adj.strokes.append(stroke)
        updateLocal(adj, live: false, label: erase ? "Erase brush" : "Paint")
    }

    /// Places the selected gradient (or a new one) from `start` to `end` on the shown photo.
    func setGradient(start: CGPoint, end: CGPoint, live: Bool) {
        if selectedLocal?.kind != .gradient { addLocal(.gradient) }
        guard var adj = selectedLocal else { return }
        adj.start = sourceCurvePoint(start)
        adj.end = sourceCurvePoint(end)
        updateLocal(adj, live: live, label: "Move gradient")
    }

    // MARK: Tilt-shift

    func beginTiltShift() {
        commitPending()
        if recipe.tiltShift == nil {
            var t = TiltShift()
            t.center = sourceCurvePoint(CGPoint(x: 0.5, y: 0.55))
            t.along = sourceCurvePoint(CGPoint(x: 0.75, y: 0.55))
            apply(recipe.setting(.tiltShift(t)), label: "Tilt-shift")
        }
        tool = .tiltShift
    }

    func setTiltShift(_ t: TiltShift, live: Bool = true) {
        let r = recipe.setting(.tiltShift(t))
        if live { setLive(r, label: "Tilt-shift") } else { apply(r, label: "Tilt-shift") }
    }

    func removeTiltShift() {
        tool = .none
        apply(recipe.removing(.tiltShift), label: "Remove tilt-shift")
    }

    /// The band's middle and direction on the shown photo, in view points.
    func tiltShiftOnScreen(in size: CGSize) -> (center: CGPoint, angle: Double)? {
        guard let t = recipe.tiltShift else { return nil }
        let c = displayPointUnclamped(t.center), a = displayPointUnclamped(t.along)
        let cv = CGPoint(x: c.x * size.width, y: c.y * size.height)
        let av = CGPoint(x: a.x * size.width, y: a.y * size.height)
        return (cv, atan2(av.y - cv.y, av.x - cv.x))
    }

    /// Moves or turns the band, from view points on the shown photo.
    func placeTiltShift(center: CGPoint, angle: Double, in size: CGSize, live: Bool) {
        guard var t = recipe.tiltShift else { return }
        let reach = min(size.width, size.height) * 0.2
        let along = CGPoint(x: center.x + cos(angle) * reach, y: center.y + sin(angle) * reach)
        t.center = sourceCurvePoint(CGPoint(x: center.x / size.width, y: center.y / size.height))
        t.along = sourceCurvePoint(CGPoint(x: along.x / size.width, y: along.y / size.height))
        setTiltShift(t, live: live)
    }

    // MARK: Background blur

    /// Finds the subject and blurs what's behind it; or turns the blur off.
    func toggleBackgroundBlur() {
        if recipe.backgroundBlur != nil {
            apply(recipe.removing(.backgroundBlur), label: "Remove background blur")
            return
        }
        guard let proxyImage else { return }
        let before = SendableImage(image: RecipeRenderer.apply(recipe.prefix(before: .backgroundBlur), to: proxyImage))
        let engine = engine
        isBusy = true
        toolMessage = nil
        Task {
            let mask = await Task.detached(priority: .userInitiated) { engine.subjectMask(for: before.image) }.value
            isBusy = false
            guard let mask else {
                toolMessage = SubjectError.noSubject.localizedDescription
                return
            }
            apply(recipe.setting(.backgroundBlur(BackgroundBlur(amount: 0.5, mask: mask))), label: "Background blur")
        }
    }

    func setBackgroundBlurAmount(_ amount: Double) {
        guard var b = recipe.backgroundBlur else { return }
        b.amount = amount
        setLive(recipe.setting(.backgroundBlur(b)), label: "Background blur")
    }

    // MARK: Lens

    func setLens(_ lens: LensCorrection) {
        setLive(recipe.setting(.lens(lens)), label: "Lens correction")
    }
}
