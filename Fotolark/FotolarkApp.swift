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
        .commands { FotolarkCommands(model: model) }
    }
}

/// Receives photos opened from Finder ("Open With", double-click when Fotolark is the
/// default app) or dropped on the Dock icon.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppModel.shared.open(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.editor?.saveNow()
        }
    }
}
