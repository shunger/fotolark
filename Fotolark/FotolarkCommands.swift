import FotolarkKit
import SwiftUI

struct FotolarkCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("neutralGrayBackground") private var neutralGray = false
    @AppStorage("showInfo") private var showInfo = true
    @AppStorage("showFilmstrip") private var showFilmstrip = true

    private var editor: PhotoEditor? { model.editor }

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "shortcuts") }
                .keyboardShortcut("/")
        }

        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.showOpenPanel() }
                .keyboardShortcut("o")
            Button("Add Folder…") { model.addFolderWithPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Import from Folder or Drive…") { model.importFromFolderWithPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export…") { model.sheet = .export }
                .keyboardShortcut("e")
                .disabled(model.targetPhotos.isEmpty)
            Button("Save Over Original…") { model.isConfirmingOverwrite = true }
                .disabled(!canSaveOver)
            Divider()
            Button("Revert to Original") { editor?.revertToOriginal() }
                .disabled(!(editor?.isEdited ?? false))
            Button("Show Backups in Finder") { model.showBackupsInFinder() }
            Divider()
            Button("Show in Finder") { model.revealInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.targetPhotos.isEmpty)
            Button("Rename…") { model.sheet = .rename }
                .disabled(model.targetPhotos.count != 1)
            Button("Copy To…") { model.moveOrCopyTargets(copy: true) }
                .disabled(model.targetPhotos.isEmpty)
            Button("Move To…") { model.moveOrCopyTargets(copy: false) }
                .disabled(model.targetPhotos.isEmpty)
            Button("Move to Trash") { model.moveTargetsToTrash() }
                .keyboardShortcut(.delete)
                // Off while a sheet is open, so ⌘⌫ in a text field never trashes a photo.
                .disabled(model.targetPhotos.isEmpty || model.sheet != nil)
        }

        CommandGroup(replacing: .undoRedo) {
            Button(editor?.history.undoLabel.map { "Undo \($0)" } ?? "Undo") { editor?.undo() }
                .keyboardShortcut("z")
                .disabled(!(editor?.history.canUndo ?? false))
            Button(editor?.history.redoLabel.map { "Redo \($0)" } ?? "Redo") { editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(editor?.history.canRedo ?? false))
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Edits") { model.copyEdits() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.editsToCopy == nil)
            Button("Paste Edits") { model.pasteEdits() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!model.canPasteEdits)
        }

        CommandMenu("Bulk") {
            ForEach(BulkTool.allCases) { tool in
                Button("\(tool.title)…") { model.sheet = .bulk(tool) }
            }
            .disabled(model.targetPhotos.isEmpty)
        }

        CommandMenu("Photo") {
            Group {
                Button("Magic Fix") { editor?.toggleAutoFix(.magicFix) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Auto Contrast") { editor?.toggleAutoFix(.autoContrast) }
                Button("Auto Color") { editor?.toggleAutoFix(.autoColor) }
                Button("Neutral Color Picker") { editor?.beginWhiteBalance() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                Divider()
                Button("Crop…") { editor?.beginCrop(); model.zoomToFit() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Straighten…") { editor?.tool = .straighten; model.zoomToFit() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Auto-Straighten") { editor?.autoStraighten() }
                Button("Red-Eye…") { editor?.beginRedEye(); model.zoomToFit() }
                Button("Rotate Left") { editor?.rotate(clockwise: false) }
                    .keyboardShortcut("[")
                Button("Rotate Right") { editor?.rotate(clockwise: true) }
                    .keyboardShortcut("]")
                Button("Flip Horizontal") { editor?.flip(horizontally: true) }
                Button("Flip Vertical") { editor?.flip(horizontally: false) }
                Button("Resize…") { model.sheet = .resize }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Previous Photo") { model.previous() }
                    .disabled(!model.canGoPrevious)
                Button("Next Photo") { model.next() }
                    .disabled(!model.canGoNext)
            }
            .disabled(editor == nil)
        }

        CommandGroup(before: .toolbar) {
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-")
            Button("Zoom to Fit") { model.zoomToFit() }
                .keyboardShortcut("0")
            Button("Actual Size") { model.zoomToActualSize() }
                .keyboardShortcut("1")
            Divider()
            Toggle("Neutral Gray Background", isOn: $neutralGray)
            Toggle("Show Editing Panel", isOn: $showInspector)
                .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Show Info", isOn: $showInfo)
                .keyboardShortcut("i")
            Toggle("Show Filmstrip", isOn: $showFilmstrip)
            Button("Back to All Photos") { model.closeEditor() }
                .disabled(editor == nil)
            Divider()
        }
    }

    private var canSaveOver: Bool {
        guard let editor, editor.isEdited else { return false }
        return OriginalOverwriter.format(for: editor.info) != nil
    }
}
