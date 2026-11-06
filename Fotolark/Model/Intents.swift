import AppIntents
import FotolarkKit
import Foundation
import UniformTypeIdentifiers

/// Formats offered in Shortcuts.
enum PhotoFormat: String, AppEnum {
    case jpeg, png, heic, tiff

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Photo Format"
    static let caseDisplayRepresentations: [PhotoFormat: DisplayRepresentation] = [
        .jpeg: "JPEG", .png: "PNG", .heic: "HEIC", .tiff: "TIFF",
    ]

    var exportFormat: ExportFormat { ExportFormat(rawValue: rawValue) ?? .jpeg }
}

/// Runs a quick action on each file Shortcuts passes in and hands back new files.
private func runQuickAction(_ action: QuickActions.Action, on files: [IntentFile], format: ExportFormat? = nil) throws -> [IntentFile] {
    let engine = EditEngine()
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Fotolark Shortcuts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    // Files that aren't photos are skipped (macOS 14 can't limit the picker to images).
    return try files.compactMap { file in
        let input = temp.appendingPathComponent(file.filename.isEmpty ? "photo.jpg" : file.filename)
        try file.data.write(to: input)
        guard ImageLoader.canOpen(input) || (try? ImageLoader.info(for: input)) != nil else { return nil }
        let result = try QuickActions.run(action, on: input, format: format, engine: engine)
        let type = UTType(filenameExtension: (result.name as NSString).pathExtension) ?? .image
        return IntentFile(data: result.data, filename: result.name, type: type)
    }
}

struct ResizePhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Resize Photos"
    static let description = IntentDescription("Makes smaller copies of photos. The originals aren't changed.")

    @Parameter(title: "Photos")
    var photos: [IntentFile]

    @Parameter(title: "Longest Side (pixels)", default: 2048, inclusiveRange: (16, 20000))
    var longestSide: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Resize \(\.$photos) to \(\.$longestSide) pixels")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try runQuickAction(.resize(longestSide: longestSide), on: photos))
    }
}

struct ConvertPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Photos"
    static let description = IntentDescription("Makes copies of photos in another format, such as HEIC to JPEG.")

    @Parameter(title: "Photos")
    var photos: [IntentFile]

    @Parameter(title: "Format", default: .jpeg)
    var format: PhotoFormat

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$photos) to \(\.$format)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try runQuickAction(.convert(format.exportFormat), on: photos))
    }
}

struct AutoFixPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Auto-Fix Photos"
    static let description = IntentDescription("Makes copies with Magic fix applied: exposure, contrast and color fixed in one step.")

    @Parameter(title: "Photos")
    var photos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Auto-fix \(\.$photos)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        .result(value: try runQuickAction(.autoFix, on: photos))
    }
}

struct FotolarkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ResizePhotosIntent(), phrases: ["Resize photos with \(.applicationName)"],
                    shortTitle: "Resize Photos", systemImageName: "arrow.up.left.and.arrow.down.right")
        AppShortcut(intent: ConvertPhotosIntent(), phrases: ["Convert photos with \(.applicationName)"],
                    shortTitle: "Convert Photos", systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: AutoFixPhotosIntent(), phrases: ["Auto-fix photos with \(.applicationName)"],
                    shortTitle: "Auto-Fix Photos", systemImageName: "wand.and.stars")
    }
}
