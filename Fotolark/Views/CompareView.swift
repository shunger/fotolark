import FotolarkKit
import SwiftUI

/// Two to four photos side by side. Zooming and panning one zooms and pans them all,
/// so the same spot can be compared closely (for example, which shot is sharpest).
struct CompareView: View {
    @Bindable var model: AppModel
    let photos: [URL]

    @State private var images: [URL: CGImage] = [:]
    /// 1 = fit; larger zooms in.
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat?
    /// The point of each photo shown at the middle of its pane (normalized).
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var dragBase: CGPoint?
    @State private var chosen: URL?
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorSchemeOutside

    var body: some View {
        GeometryReader { geo in
            let columns = photos.count == 4 ? 2 : photos.count
            let rows = photos.count == 4 ? 2 : 1
            let paneSize = CGSize(width: (geo.size.width - CGFloat(columns - 1) * 4) / CGFloat(columns),
                                  height: (geo.size.height - CGFloat(rows - 1) * 4) / CGFloat(rows))
            VStack(spacing: 4) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: 4) {
                        ForEach(0..<columns, id: \.self) { c in
                            let i = r * columns + c
                            if i < photos.count { pane(photos[i], size: paneSize) }
                        }
                    }
                }
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { v in
                        let base = pinchBase ?? zoom
                        if pinchBase == nil { pinchBase = zoom }
                        zoom = min(max(base * v.magnification, 1), 12)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        let base = dragBase ?? center
                        if dragBase == nil { dragBase = center }
                        // Move by the drag, measured against the zoomed pane.
                        let w = paneSize.width * zoom, h = paneSize.height * zoom
                        center = CGPoint(x: min(max(base.x - v.translation.width / w, 0), 1),
                                         y: min(max(base.y - v.translation.height / h, 0), 1))
                    }
                    .onEnded { _ in dragBase = nil }
            )
        }
        .background(PhotoBackdrop())
        .environment(\.colorScheme, PhotoBackground.current == .system ? colorSchemeOutside : .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { model.endCompare(); return .handled }
        .onKeyPress(.return) {
            if let chosen { model.endCompare(); model.openEditor(chosen) }
            return .handled
        }
        .task(id: photos) { await load() }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("All Photos", systemImage: "square.grid.2x2") { model.endCompare() }
                    .help("Back to all photos (Esc)")
            }
            ToolbarItemGroup {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = max(zoom / 1.5, 1) }
                Button("Fit", systemImage: "arrow.down.right.and.arrow.up.left") { zoom = 1; center = CGPoint(x: 0.5, y: 0.5) }
                Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = min(zoom * 1.5, 12) }
                Button("Edit", systemImage: "slider.horizontal.3") {
                    if let chosen { model.endCompare(); model.openEditor(chosen) }
                }
                .disabled(chosen == nil)
                .help("Edit the chosen photo (Return)")
            }
        }
    }

    private func pane(_ url: URL, size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.15)
            if let cg = images[url] {
                let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
                let s = min(size.width / iw, size.height / ih) * zoom
                let w = iw * s, h = ih * s
                // Keep the shared center point in the middle, without showing past the edges.
                let ox = w <= size.width ? 0 : min(max((0.5 - center.x) * w, size.width / 2 - w / 2), w / 2 - size.width / 2)
                let oy = h <= size.height ? 0 : min(max((0.5 - center.y) * h, size.height / 2 - h / 2), h / 2 - size.height / 2)
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(zoom > 2 ? .medium : .high)
                    .frame(width: w, height: h)
                    .offset(x: ox, y: oy)
                    .frame(width: size.width, height: size.height)
            } else {
                ProgressView().frame(width: size.width, height: size.height)
            }
            HStack(spacing: 6) {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if model.recipes[url] != nil { Image(systemName: "slider.horizontal.3").accessibilityLabel("Edited") }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay {
            Rectangle().strokeBorder(chosen == url ? Color.accentColor : .clear, lineWidth: 3)
        }
        .contentShape(Rectangle())
        // Double-click first, so SwiftUI tells the two apart.
        .onTapGesture(count: 2) { model.endCompare(); model.openEditor(url) }
        .onTapGesture { chosen = url }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen == url ? [.isButton, .isSelected] : .isButton)
    }

    private func load() async {
        let engine = model.engine
        for url in photos where images[url] == nil {
            let recipe = model.recipe(for: url)
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let preview = try? ImageLoader.loadPreview(url, maxPixelSize: 3000) else { return nil }
                return engine.render(recipe, source: preview, includeResize: false)
            }.value
            images[url] = image
        }
    }
}
