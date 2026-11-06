import AppKit
import FotolarkKit

/// Finder's right-click Services: "Resize with Fotolark" and "Quick Fix with Fotolark".
/// The names and the file types are declared under NSServices in Info.plist.
final class ServiceProvider: NSObject {
    @objc func resizeWithFotolark(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.photos(on: pboard)
        MainActor.assumeIsolated { AppModel.shared.handleService(urls, quickFix: false) }
    }

    @objc func quickFixWithFotolark(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.photos(on: pboard)
        MainActor.assumeIsolated { AppModel.shared.handleService(urls, quickFix: true) }
    }

    static func photos(on pboard: NSPasteboard) -> [URL] {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(ImageLoader.canOpen)
    }
}

extension AppModel {
    /// Photos sent from Finder: shown together, then the Resize tool opens, or Magic fix
    /// is added to each (non-destructively, like the Bulk menu's).
    func handleService(_ urls: [URL], quickFix: Bool) {
        guard !urls.isEmpty else { return }
        NSApp.activate()
        open(urls)
        if urls.count > 1 || !quickFix {
            closeEditor()
            selection = Set(urls.map(\.standardizedFileURL))
        }
        let targets = urls.map(\.standardizedFileURL)
        if quickFix {
            // A placeholder Magic fix: it is worked out again for each photo.
            let magic = EditRecipe().setting(.magicFix(FilterChain(steps: [FilterStep(name: "CIVibrance", parameters: [:])])))
            bulkApplyEdits(targets, edits: magic, title: "Quick fix", addOnly: true)
        } else {
            sheet = .bulk(.resize)
        }
    }
}
