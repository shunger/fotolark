import FotolarkKit
import SwiftUI
import UniformTypeIdentifiers

/// The photo, fitted to the window or zoomed, with the crop and straighten overlays.
struct CanvasView: View {
    @Bindable var editor: PhotoEditor
    @Bindable var model: AppModel
    @Environment(\.displayScale) private var displayScale
    @AppStorage("neutralGrayBackground") private var neutralGray = false
    @State private var pinchBase: CGFloat?
    @FocusState private var focused: Bool

    private let margin: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let shown = editor.shownSize
            let fit = fitScale(for: shown, in: geo.size)
            let scale = max(model.zoomScale ?? fit, fit)
            let size = CGSize(width: CGFloat(shown.width) * scale, height: CGFloat(shown.height) * scale)
            ZStack {
                background
                if scale <= fit * 1.001 {
                    photo(size: size)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        photo(size: size).padding(margin)
                    }
                    .defaultScrollAnchor(.center)
                }
                if editor.preview == nil || editor.isBusy {
                    ProgressView().controlSize(.large)
                }
            }
            .onAppear { report(fit: fit, size: size) }
            .onChange(of: size) { report(fit: fit, size: size) }
            .gesture(magnify(fit: fit, current: scale))
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        // Arrow keys: previous/next photo, or move the crop (⇧ resizes it) while cropping.
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            if editor.tool == .crop {
                nudgeCrop(press.key, resize: press.modifiers.contains(.shift))
                return .handled
            }
            switch press.key {
            case .leftArrow: model.previous()
            case .rightArrow: model.next()
            default: return .ignored
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard editor.tool != .none else { return .ignored }
            if editor.tool == .crop { editor.applyCrop() } else { editor.tool = .none }
            return .handled
        }
        .onKeyPress(.escape) {
            guard editor.tool != .none else {
                model.closeEditor()
                return .handled
            }
            if editor.tool == .crop { editor.cancelCrop() } else { editor.tool = .none }
            return .handled
        }
        // Hold the backslash key to see the original.
        .onKeyPress(characters: ["\\"], phases: [.down, .up]) { press in
            editor.showOriginal = press.phase == .down
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo")
    }

    @ViewBuilder
    private var background: some View {
        if neutralGray {
            Color(white: 0.45)
        } else {
            Color(nsColor: .underPageBackgroundColor)
        }
    }

    private func photo(size: CGSize) -> some View {
        ZStack {
            if let cg = editor.preview {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .onDrag { dragProvider() }
                    .accessibilityLabel(editor.showOriginal ? "Original photo" : "Edited photo")
            }
            switch editor.tool {
            case .crop:
                CropOverlay(rect: $editor.cropDraft, aspect: editor.normalizedCropAspect)
            case .straighten:
                GridOverlay(divisions: 8)
            case .retouch:
                RetouchOverlay(editor: editor)
            case .focus:
                FocusOverlay(editor: editor)
            case .text:
                TextOverlayEditor(editor: editor)
            case .redEye:
                GeometryReader { geo in
                    let longest = max(geo.size.width, geo.size.height)
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture(coordinateSpace: .local) { location in
                                editor.addRedEye(atDisplayPoint: CGPoint(x: location.x / geo.size.width,
                                                                         y: location.y / geo.size.height))
                            }
                            .onContinuousHover { phase in
                                if case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                            }
                        ForEach(Array(editor.redEyeDisplaySpots.enumerated()), id: \.offset) { _, spot in
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 1.5)
                                .shadow(color: .black.opacity(0.6), radius: 1)
                                .frame(width: spot.radius * longest * 2.4, height: spot.radius * longest * 2.4)
                                .position(x: spot.center.x * geo.size.width, y: spot.center.y * geo.size.height)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .accessibilityLabel("Click a red eye to fix it")
            case .whiteBalance:
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            editor.pickWhiteBalance(at: CGPoint(x: location.x / geo.size.width,
                                                                y: location.y / geo.size.height))
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active: NSCursor.crosshair.set()
                            case .ended: NSCursor.arrow.set()
                            }
                        }
                }
                .accessibilityLabel("Click something that should be gray")
            case .none:
                EmptyView()
            }
            if editor.showOriginal {
                Text("Original")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Moves (or with ⇧, resizes) the crop by 1% so cropping works without a mouse.
    private func nudgeCrop(_ key: KeyEquivalent, resize: Bool) {
        let step = 0.01
        var dx = 0.0, dy = 0.0
        switch key {
        case .leftArrow: dx = -step
        case .rightArrow: dx = step
        case .upArrow: dy = -step
        default: dy = step
        }
        var r = editor.cropDraft
        if resize {
            r.width += dx
            r.height += dy
            if let a = editor.normalizedCropAspect {
                if dx != 0 { r.height = r.width / a } else { r.width = r.height * a }
            }
        } else {
            r.x += dx
            r.y += dy
        }
        editor.cropDraft = r.clamped(minSize: 0.03)
    }

    /// Dragging the photo out hands over an edited JPEG copy (or the original if unedited).
    private func dragProvider() -> NSItemProvider {
        let url = editor.url
        let recipe = model.recipe(for: url)
        guard !recipe.isEmpty, editor.tool == .none else { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        let engine = model.engine
        let provider = NSItemProvider()
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { done in
            let copies = AppModel.renderForSharing([url], recipes: [url: recipe], engine: engine)
            done(copies.first, false, copies.first == nil ? CocoaError(.fileWriteUnknown) : nil)
            return nil
        }
        return provider
    }

    /// Points per image pixel that fit the whole photo in the window.
    private func fitScale(for shown: PixelSize, in available: CGSize) -> CGFloat {
        let w = max(available.width - margin * 2, 50)
        let h = max(available.height - margin * 2, 50)
        return min(w / CGFloat(max(shown.width, 1)), h / CGFloat(max(shown.height, 1)))
    }

    private func report(fit: CGFloat, size: CGSize) {
        model.fitScale = fit
        model.displayScale = displayScale
        editor.displayPixelsNeeded = Int(max(size.width, size.height) * displayScale)
    }

    private func magnify(fit: CGFloat, current: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? current
                if pinchBase == nil { pinchBase = current }
                model.setZoom(base * value.magnification)
            }
            .onEnded { _ in pinchBase = nil }
    }
}

/// Evenly spaced lines for lining up the horizon while straightening.
struct GridOverlay: View {
    let divisions: Int

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1..<divisions {
                let x = size.width * CGFloat(i) / CGFloat(divisions)
                let y = size.height * CGFloat(i) / CGFloat(divisions)
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.black.opacity(0.35)), lineWidth: 1.5)
            context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Brush painting for spot heal, clone and soften skin.
struct RetouchOverlay: View {
    @Bindable var editor: PhotoEditor
    @State private var hover: CGPoint?
    @State private var stroke: [CGPoint] = []
    @State private var isSettingSource = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let longest = max(size.width, size.height)
            ZStack {
                Color.clear.contentShape(Rectangle())
                // The stroke being painted.
                Path { p in
                    guard let first = stroke.first else { return }
                    p.move(to: first)
                    for pt in stroke.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: editor.brushSize * 2, lineCap: .round, lineJoin: .round))
                // Brush outline.
                if let hover {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 1)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .frame(width: editor.brushSize * 2, height: editor.brushSize * 2)
                        .position(hover)
                }
                // Clone source marker.
                if editor.retouchTool == .clone, let src = editor.cloneSourceDisplayPoint {
                    Image(systemName: "plus.circle")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 1)
                        .position(x: src.x * size.width, y: src.y * size.height)
                        .accessibilityLabel("Clone source")
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = p; NSCursor.crosshair.set()
                case .ended: hover = nil; NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if stroke.isEmpty && NSEvent.modifierFlags.contains(.option) && editor.retouchTool == .clone {
                            isSettingSource = true
                        }
                        hover = value.location
                        if isSettingSource { return }
                        if stroke.last.map({ hypot($0.x - value.location.x, $0.y - value.location.y) > 2 }) ?? true {
                            stroke.append(value.location)
                        }
                    }
                    .onEnded { value in
                        defer { stroke = []; isSettingSource = false }
                        let norm = { (p: CGPoint) in CGPoint(x: p.x / size.width, y: p.y / size.height) }
                        if isSettingSource {
                            editor.setCloneSource(atDisplayPoint: norm(value.location))
                            return
                        }
                        let pts = (stroke.isEmpty ? [value.location] : stroke).map(norm)
                        editor.addStroke(displayPoints: pts, radiusFraction: editor.brushSize / longest)
                    }
            )
        }
        .accessibilityLabel("Paint over the area to retouch")
    }
}
