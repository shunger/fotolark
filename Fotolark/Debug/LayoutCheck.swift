#if DEBUG
import AppKit
import FotolarkKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Debug builds only: renders each screen at fixed sizes, reports any whose content
/// needs more width than it gets (the kind of bug that pushes a panel over the photo
/// or clips the window), and saves a picture of each. Run with
/// `FOTOLARK_LAYOUTCHECK=<folder>`; check.sh does this after every build.
@MainActor
enum LayoutCheck {
    private static var overflowCount = 0
    private static var out: URL!

    static func runIfAsked() {
        guard let path = ProcessInfo.processInfo.environment["FOTOLARK_LAYOUTCHECK"] else { return }
        out = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Task {
            try? await Task.sleep(for: .seconds(1))
            await run()
            print("LAYOUT done, \(overflowCount) overflow\(overflowCount == 1 ? "" : "s")")
            exit(overflowCount == 0 ? 0 : 1)
        }
    }

    private static func run() async {
        let model = AppModel.shared
        model.sheet = nil
        let savedSection = UserDefaults.standard.string(forKey: "inspector.openSection")
        defer { UserDefaults.standard.set(savedSection, forKey: "inspector.openSection") }

        // The checker must catch a view that is too wide, or it proves nothing.
        check("self-test (must overflow)", HStack { Color.red.frame(width: 400, height: 20) }.fixedSize(), width: 290,
              expectOverflow: true)

        // Sample photos to show.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LayoutCheck", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photos = (0..<6).map { i -> URL in
            let url = dir.appendingPathComponent("IMG_\(1000 + i).jpg")
            writeSample(url, portrait: i % 2 == 0, hue: Double(i) / 6)
            return url
        }
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library"))

        // Import screen at narrow and wide detail widths.
        let source = FolderImportSource(folder: dir, thumbnails: model.thumbnails)
        try? await Task.sleep(for: .seconds(1))
        for w in [530.0, 800, 1200] {
            check("import", ImportView(model: model, source: source), width: w, height: 700)
        }

        // Editing panel: every section open in turn, and every tool.
        guard let editor = try? PhotoEditor(url: photos[0], engine: model.engine, store: store) else {
            print("LAYOUT could not open a sample photo"); overflowCount += 1; return
        }
        try? await Task.sleep(for: .seconds(1))
        editor.setTiltShift(TiltShift(), live: false)
        editor.addLocal(.brush)
        editor.setBorder(Border(style: .rounded), live: false)
        let sections = ["Basic fixes", "Brush and gradient", "Crop and rotate", "Effects", "Light", "Color", "Detail",
                        "Curves", "Levels", "Color ranges", "Lens correction", "Border", "Vignette", "Versions", "History"]
        for title in sections {
            InspectorAccordion.shared.setOpen(title)
            editor.tool = .none
            check("panel: \(title)", InspectorView(editor: editor, model: model), width: 290, height: 900)
        }
        let tools: [(PhotoEditor.Tool, String)] = [(.crop, "crop"), (.straighten, "straighten"), (.whiteBalance, "white balance"),
                                                   (.redEye, "red-eye"), (.retouch, "retouch"), (.text, "text"),
                                                   (.local, "brush and gradient"), (.tiltShift, "tilt-shift"),
                                                   (.markup, "shapes"), (.focus, "focal B&W")]
        for (tool, name) in tools {
            editor.tool = tool
            check("tool: \(name)", InspectorView(editor: editor, model: model), width: 290, height: 900)
        }
        editor.tool = .none

        // The photo itself, plain and with before and after side by side.
        editor.setAdjustment(\.saturation, to: -1, label: "Saturation")
        editor.commitPending()
        try? await Task.sleep(for: .seconds(1))
        check("canvas", CanvasView(editor: editor, model: model), width: 800, height: 600)
        editor.splitCompare = true
        try? await Task.sleep(for: .seconds(1.5))
        check("canvas: before and after", CanvasView(editor: editor, model: model), width: 800, height: 600)
        editor.splitCompare = false

        // Undo survives reopening (as after quitting): a fresh editor picks the history up.
        let histories = HistoryStore(directory: dir.appendingPathComponent("History"))
        if let first = try? PhotoEditor(url: photos[1], engine: model.engine, store: store, historyStore: histories) {
            try? await Task.sleep(for: .milliseconds(500))
            first.setAdjustment(\.exposure, to: 0.5, label: "Exposure")
            first.commitPending()
            first.saveNow()
            let again = try? PhotoEditor(url: photos[1], engine: model.engine, store: store, historyStore: histories)
            let ok = again?.history.canUndo == true && again?.history.undoLabel == "Exposure"
            if !ok { overflowCount += 1 }
            print("LAYOUT \(ok ? "pass" : "FAIL") undo history survives reopening")
        }

        // Sheets and windows at their own size, which must fit a small (1280 × 800) screen.
        let urls = photos
        check("export sheet", ExportSheet(model: model, photos: urls), width: 1200, height: 740, fitsScreen: true)
        for tool in BulkTool.allCases {
            check("bulk: \(tool.title)", BulkSheet(model: model, photos: urls, tool: tool), width: 1200, height: 740, fitsScreen: true)
        }
        check("print", PageSheet(model: model, photos: urls, mode: .print), width: 1200, height: 740, fitsScreen: true)
        check("contact sheet", PageSheet(model: model, photos: urls, mode: .contactSheet), width: 1200, height: 740, fitsScreen: true)
        check("collage", CollageSheet(model: model, photos: urls), width: 1200, height: 740, fitsScreen: true)
        check("welcome", WelcomeTour(model: model), width: 1200, height: 740, fitsScreen: true)
        check("new album", AlbumNameSheet(model: model, photos: urls), width: 1200, height: 740, fitsScreen: true)
        check("resize", ResizeSheet(editor: editor), width: 1200, height: 740, fitsScreen: true)
        check("settings", SettingsView(model: model), width: 1200, height: 740, fitsScreen: true)
        check("help", HelpView(), width: 760, height: 520)
        check("empty window", EmptyStateView(model: model, isDropTargeted: false), width: 530, height: 600)
        model.notice = AppModel.Notice(text: "Done: Import 3,365 from a very long device name iPhone-S of Steve",
                                       detail: "2 skipped", folder: dir, hasProblems: true)
        check("notice", NoticeView(model: model, notice: model.notice!), width: 530, height: 80)
        model.notice = nil
        check("people", PeopleView(model: model), width: 530, height: 600)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Asks SwiftUI how wide the view needs to be when offered `width`; more than that
    /// means it will spill past its edges. Also saves a picture of it.
    private static func check<V: View>(_ name: String, _ view: V, width: CGFloat, height: CGFloat = 800,
                                       fitsScreen: Bool = false, expectOverflow: Bool = false) {
        let host = NSHostingController(rootView: view)
        // Sheets and windows are offered a small laptop screen; panels their own width.
        let offer = fitsScreen ? CGSize(width: 1200, height: 760) : CGSize(width: width, height: height)
        var need = host.sizeThatFits(in: offer)
        // Views that stretch report infinity; they fit by definition.
        if !need.width.isFinite { need.width = offer.width }
        if !need.height.isFinite { need.height = offer.height }
        let tooWide = need.width > offer.width + 0.5 || (fitsScreen && need.height > offer.height + 0.5)
        let ok = tooWide == expectOverflow
        if !ok { overflowCount += 1 }
        let label = tooWide ? "OVERFLOW" : "ok"
        print("LAYOUT \(ok ? "pass" : "FAIL") \(label) \(name) @\(Int(width)) needs \(Int(need.width.rounded()))×\(Int(need.height.rounded()))")
        if !expectOverflow { snapshot(view, name: "\(name) @\(Int(width))", size: CGSize(width: fitsScreen ? min(need.width, 1200) : width,
                                                                                        height: min(fitsScreen ? need.height : height, 1600))) }
    }

    private static func snapshot<V: View>(_ view: V, name: String, size: CGSize) {
        for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            // The app's own environment wins inside views that set one (like the canvas).
        let content = view.environment(\.colorScheme, scheme)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: content)
            host.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "") + " (\(suffix)).png"
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(file))
        }
    }

    private static func writeSample(_ url: URL, portrait: Bool, hue: Double) {
        let w = portrait ? 300 : 400, h = portrait ? 400 : 300
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        let c = NSColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1)
        ctx.setFillColor(c.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
#endif
