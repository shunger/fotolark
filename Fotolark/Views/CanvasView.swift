import FotolarkKit
import SwiftUI

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
        .onKeyPress(.leftArrow) { model.previous(); return .handled }
        .onKeyPress(.rightArrow) { model.next(); return .handled }
        .onKeyPress(.return) {
            guard editor.tool != .none else { return .ignored }
            if editor.tool == .crop { editor.applyCrop() } else { editor.tool = .none }
            return .handled
        }
        .onKeyPress(.escape) {
            guard editor.tool != .none else { return .ignored }
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
                    .accessibilityLabel(editor.showOriginal ? "Original photo" : "Edited photo")
            }
            switch editor.tool {
            case .crop:
                CropOverlay(rect: $editor.cropDraft, aspect: editor.normalizedCropAspect)
            case .straighten:
                GridOverlay(divisions: 8)
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
