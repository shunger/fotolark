import AppKit
import FotolarkKit
import SwiftUI

@main
struct FotolarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Fotolark", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            FotolarkCommands(model: model)
            // View › Show Toolbar and Customize Toolbar…
            ToolbarCommands()
        }

        Settings {
            SettingsView(model: model)
        }

        Window("Fotolark Help", id: "help") {
            HelpView()
        }

        Window("Keyboard Shortcuts", id: "shortcuts") {
            ShortcutsView()
        }
        .windowResizability(.contentSize)
    }
}

/// Receives photos opened from Finder ("Open With", double-click when Fotolark is the
/// default app) or dropped on the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        #if DEBUG
        MainActor.assumeIsolated { LayoutCheck.runIfAsked() }
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppModel.shared.open(urls)
        }
    }

    /// Edit › Select All (⌘A) reaches here only when nothing focused handled it (text
    /// fields and the photo grid handle their own). The import screen selects all its photos.
    @objc func selectAll(_ sender: Any?) {
        MainActor.assumeIsolated {
            let model = AppModel.shared
            if case .importing = model.source, model.editor == nil { model.selectAllRequests += 1 }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.editor?.saveNow()
        }
    }
}
