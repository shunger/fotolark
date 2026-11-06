import AppKit
import AVFoundation
import FotolarkKit
import SwiftUI
import UniformTypeIdentifiers

/// Plays photos full screen: timing, transitions, shuffle and optional music.
@MainActor @Observable
final class SlideshowPlayer {
    let urls: [URL]
    private let recipes: [URL: EditRecipe]
    private let engine: EditEngine
    private let maxPixelSize: Int

    var settings: SlideshowSettings {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: "slideshow.settings")
            if settings.shuffle != oldValue.shuffle { reorder() }
            if settings.musicBookmark != oldValue.musicBookmark { startMusic() }
            if settings.seconds != oldValue.seconds || settings.transition != oldValue.transition { restartTimer() }
        }
    }

    private(set) var image: CGImage?
    /// Changes with every slide, so SwiftUI animates between them.
    private(set) var slideID = 0
    /// True when the last move went backwards (slides come in from the left).
    private(set) var wentBack = false
    private(set) var position = 0
    private(set) var isPlaying = true
    private(set) var order: [Int] = []
    private var cache: [Int: CGImage] = [:]
    private var timer: Task<Void, Never>?
    private var audio: AVAudioPlayer?
    private var musicURL: URL?
    var onClose: (() -> Void)?

    init(urls: [URL], start: Int, recipes: [URL: EditRecipe], engine: EditEngine, maxPixelSize: Int) {
        self.urls = urls
        self.recipes = recipes
        self.engine = engine
        self.maxPixelSize = maxPixelSize
        settings = UserDefaults.standard.data(forKey: "slideshow.settings")
            .flatMap { try? JSONDecoder().decode(SlideshowSettings.self, from: $0) } ?? SlideshowSettings()
        order = settings.order(count: urls.count, start: start)
    }

    var currentURL: URL? { order.isEmpty ? nil : urls[order[position]] }
    var positionText: String { "\(position + 1) of \(order.count)" }

    func start() {
        Task {
            if await render(position) != nil {
                await show(position, animated: false)
            } else {
                await advance(by: 1)
            }
            restartTimer()
        }
        startMusic()
    }

    func stop() {
        timer?.cancel()
        if let audio {
            audio.setVolume(0, fadeDuration: 0.8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { audio.stop() }
        }
        musicURL?.stopAccessingSecurityScopedResource()
        onClose?()
    }

    func togglePlaying() {
        isPlaying.toggle()
        if isPlaying { audio?.play(); restartTimer() } else { audio?.pause(); timer?.cancel() }
    }

    func next() { Task { await advance(by: 1); restartTimer() } }
    func previous() { Task { await advance(by: -1); restartTimer() } }

    // MARK: Music

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose a song or other audio file to play during slideshows"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                   relativeTo: nil)
        else { return }
        settings.musicName = url.lastPathComponent
        settings.musicBookmark = bookmark
    }

    func removeMusic() {
        settings.musicBookmark = nil
        settings.musicName = nil
    }

    private func startMusic() {
        audio?.stop()
        audio = nil
        musicURL?.stopAccessingSecurityScopedResource()
        musicURL = nil
        guard let data = settings.musicBookmark else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource()
        musicURL = url
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        player.setVolume(1, fadeDuration: 1.5)
        if !isPlaying { player.pause() }
        audio = player
    }

    // MARK: Moving between photos

    private func reorder() {
        let current = order.isEmpty ? 0 : order[position]
        order = settings.order(count: urls.count, start: current)
        position = 0
        cache = cache.filter { $0.key == current }
    }

    private func restartTimer() {
        timer?.cancel()
        guard isPlaying else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = self?.settings.seconds ?? 4
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                if !settings.loop && position == order.count - 1 {
                    isPlaying = false
                    audio?.setVolume(0, fadeDuration: 2)
                    return
                }
                await advance(by: 1)
            }
        }
    }

    private func advance(by step: Int) async {
        guard !order.isEmpty else { return }
        wentBack = step < 0
        // Skip photos that can't be read.
        var next = position
        for _ in 0..<order.count {
            next = (next + step + order.count) % order.count
            if await render(next) != nil {
                await show(next, animated: true)
                return
            }
        }
    }

    private func show(_ newPosition: Int, animated: Bool) async {
        guard let image = await render(newPosition) else { return }
        position = newPosition
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animated && settings.transition != .none {
            withAnimation(.easeInOut(duration: reduceMotion ? 0.4 : 0.9)) {
                self.image = image
                slideID += 1
            }
        } else {
            self.image = image
            slideID += 1
        }
        // Get the next photo ready while this one shows; forget ones far away.
        let ahead = (newPosition + 1) % order.count
        cache = cache.filter { $0.key == newPosition || $0.key == ahead }
        _ = await render(ahead)
    }

    private func render(_ pos: Int) async -> CGImage? {
        guard order.indices.contains(pos) else { return nil }
        if let cached = cache[pos] { return cached }
        let url = urls[order[pos]]
        let recipe = recipes[url] ?? EditRecipe()
        let engine = engine
        let size = maxPixelSize
        let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let preview = try? ImageLoader.loadPreview(url, maxPixelSize: size) else { return nil }
            return engine.render(recipe, source: preview, includeResize: false)
        }.value
        if let image { cache[pos] = image }
        return image
    }
}

struct SlideshowView: View {
    @Bindable var player: SlideshowPlayer
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = player.image {
                slide(image)
                    .id(player.slideID)
                    .transition(transition)
            }
            VStack {
                Spacer()
                if controlsVisible { controls.transition(.opacity) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            player.start()
            showControlsBriefly()
        }
        .onContinuousHover { phase in
            if case .active = phase { showControlsBriefly() }
        }
        .onKeyPress(.escape) { player.stop(); return .handled }
        .onKeyPress(.space) { player.togglePlaying(); showControlsBriefly(); return .handled }
        .onKeyPress(.rightArrow) { player.next(); return .handled }
        .onKeyPress(.leftArrow) { player.previous(); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Slideshow, \(player.positionText)")
    }

    @ViewBuilder
    private func slide(_ image: CGImage) -> some View {
        let picture = Image(decorative: image, scale: 1).resizable().scaledToFit()
        if player.settings.transition == .kenBurns && !reduceMotion {
            KenBurns(seconds: player.settings.seconds + 1, seed: player.slideID) { picture }
        } else {
            picture
        }
    }

    private var transition: AnyTransition {
        switch player.settings.transition {
        case .none: .identity
        case .crossfade, .kenBurns: .opacity
        case .slide where reduceMotion: .opacity
        case .slide:
            .asymmetric(insertion: .move(edge: player.wentBack ? .leading : .trailing),
                        removal: .move(edge: player.wentBack ? .trailing : .leading))
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .help("Previous (←)").accessibilityLabel("Previous photo")
            Button { player.togglePlaying() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .help("Next (→)").accessibilityLabel("Next photo")
            Text(player.positionText).monospacedDigit().foregroundStyle(.secondary)

            Divider().frame(height: 18)
            Picker("Each photo", selection: $player.settings.seconds) {
                ForEach(SlideshowSettings.durations, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
            }
            .fixedSize()
            Picker("Transition", selection: $player.settings.transition) {
                ForEach(SlideshowSettings.Transition.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Toggle("Shuffle", isOn: $player.settings.shuffle)
            Toggle("Repeat", isOn: $player.settings.loop)

            Divider().frame(height: 18)
            Menu {
                Button("Choose Music…") { player.chooseMusic() }
                if player.settings.musicName != nil { Button("No Music") { player.removeMusic() } }
            } label: {
                Label(player.settings.musicName ?? "No Music", systemImage: "music.note")
            }
            .fixedSize()
            .help("Play a song from your Mac during the slideshow")

            Button { player.stop() } label: { Image(systemName: "xmark") }
                .help("End the slideshow (Esc)")
                .accessibilityLabel("End slideshow")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .padding(.bottom, 30)
    }

    private func showControlsBriefly() {
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// A slow zoom and drift across the photo while it's on screen.
private struct KenBurns<Content: View>: View {
    let seconds: Double
    let seed: Int
    @ViewBuilder let content: () -> Content
    @State private var progress = 0.0

    var body: some View {
        // Alternate where the zoom heads, so it doesn't feel repetitive.
        let anchors: [UnitPoint] = [.center, .topLeading, .bottomTrailing, .topTrailing, .bottomLeading]
        content()
            .scaleEffect(1 + 0.1 * progress, anchor: anchors[seed % anchors.count])
            .onAppear {
                withAnimation(.linear(duration: seconds)) { progress = 1 }
            }
    }
}

/// A borderless window covering the screen, with the Dock and menu bar hidden.
@MainActor
final class SlideshowWindow {
    private static var current: SlideshowWindow?

    private let window: NSWindow
    private let previousOptions: NSApplication.PresentationOptions

    static func show(urls: [URL], start: Int, recipes: [URL: EditRecipe], engine: EditEngine) {
        guard !urls.isEmpty, current == nil else { return }
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let pixels = Int(max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        let player = SlideshowPlayer(urls: urls, start: start, recipes: recipes, engine: engine, maxPixelSize: pixels)
        current = SlideshowWindow(player: player, screen: screen)
    }

    private init(player: SlideshowPlayer, screen: NSScreen) {
        previousOptions = NSApp.presentationOptions
        window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.title = "Slideshow"
        window.contentView = NSHostingView(rootView: SlideshowView(player: player))
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        player.onClose = { [weak self] in self?.close() }
    }

    private func close() {
        NSApp.presentationOptions = previousOptions
        window.orderOut(nil)
        Self.current = nil
    }

    /// Borderless windows can't take key presses unless they say so.
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
