import SwiftUI

/// Every keyboard shortcut, in one place (Help › Keyboard Shortcuts).
struct ShortcutsView: View {
    struct Group: Identifiable {
        let id: String
        let items: [(keys: String, action: String)]
    }

    static let groups: [Group] = [
        Group(id: "Photos and folders", items: [
            ("⌘O", "Open photos or a folder"),
            ("⇧⌘O", "Add a folder to the sidebar"),
            ("⇧⌘I", "Import from a folder or drive"),
            ("Return or double-click", "Edit the selected photo"),
            ("Arrow keys", "Move around the grid"),
            ("⌘I", "Show or hide photo details"),
            ("⌥⌘K", "Compare 2–4 selected photos"),
            ("⌥⌘P", "Slideshow (Space pauses, ← → move, Esc ends)"),
            ("⇧⌘R", "Show in Finder"),
            ("⌘⌫", "Move to Trash"),
        ]),
        Group(id: "Rating and flagging (grid or editor)", items: [
            ("1 to 5", "Give the photo that many stars"),
            ("0", "Clear the stars"),
            ("P", "Mark as a pick"),
            ("X", "Mark as rejected"),
            ("U", "Clear the flag"),
        ]),
        Group(id: "Editing", items: [
            ("← →", "Previous or next photo"),
            ("Esc", "Back to all photos (or leave a tool)"),
            ("Hold \\", "Show the original"),
            ("⇧⌘M", "Magic fix"),
            ("⌥⌘B", "Neutral color picker"),
            ("⌥⌘C", "Crop"),
            ("⌥⌘T", "Straighten"),
            ("⌥⌘H", "Retouch (spot heal, clone, soften skin)"),
            ("⌥⌘X", "Add text"),
            ("⌘[ and ⌘]", "Rotate left or right"),
            ("⌥⌘R", "Resize"),
            ("⌘Z, ⇧⌘Z", "Undo, redo"),
            ("⇧⌘C, ⇧⌘V", "Copy edits, paste edits"),
            ("⌘E", "Export"),
        ]),
        Group(id: "While cropping", items: [
            ("Arrow keys", "Move the crop"),
            ("⇧ arrow keys", "Make the crop larger or smaller"),
            ("Return", "Apply the crop"),
            ("Esc", "Cancel"),
        ]),
        Group(id: "View", items: [
            ("⌘= and ⌘-", "Zoom in and out"),
            ("⌘0", "Zoom to fit"),
            ("⌘1", "Actual size"),
            ("⌥⌘I", "Show or hide the editing panel"),
            ("⌃⌘F", "Full screen"),
            ("⌘/", "This list"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(Self.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.id).font(.headline).accessibilityAddTraits(.isHeader)
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                            ForEach(group.items, id: \.action) { item in
                                GridRow {
                                    Text(item.keys)
                                        .font(.body.monospaced())
                                        .gridColumnAlignment(.trailing)
                                        .frame(minWidth: 150, alignment: .trailing)
                                    Text(item.action)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 520)
    }
}
