import SwiftUI

/// Built-in help: topics on the left, the chosen topic on the right, with search.
struct HelpView: View {
    @State private var selection: HelpTopic.ID? = HelpTopic.all.first?.id
    @State private var search = ""

    private var shown: [HelpTopic] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return HelpTopic.all }
        return HelpTopic.all.filter { t in
            t.title.localizedCaseInsensitiveContains(q) || t.sections.contains {
                $0.heading.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q)
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(shown, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.symbol).tag(topic.id)
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search help")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let topic = HelpTopic.all.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(topic.title, systemImage: topic.symbol)
                            .font(.largeTitle.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(topic.intro).font(.title3).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(topic.sections, id: \.heading) { s in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(s.heading).font(.headline).accessibilityAddTraits(.isHeader)
                                Text(s.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Choose a topic").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

struct HelpTopic: Identifiable {
    struct Section { let heading: String; let text: String }
    var id: String { title }
    let title: String
    let symbol: String
    let intro: String
    let sections: [Section]

    static let all: [HelpTopic] = [
        HelpTopic(title: "Getting Started", symbol: "sparkles",
                  intro: "Fotolark shows the photos in your folders and lets you fix them in seconds. Your original files are never changed unless you choose Save Over Original.",
                  sections: [
                    .init(heading: "Add your folders", text: "Choose File › Add Folder… (⇧⌘O) or drag a folder onto the window. Fotolark lists every folder inside it that holds photos, and keeps the list up to date when you add or remove photos in Finder. Nothing is copied or moved."),
                    .init(heading: "Open a photo", text: "Double-click a photo, or select it and press Return. Use ← and → to move to the previous or next photo, and Esc to go back to the grid."),
                    .init(heading: "Undo anything", text: "Every change can be undone with ⌘Z, and the History list in the editing panel lets you jump back to any step. Hold the \\ key (or the eye button) to see the original."),
                  ]),
        HelpTopic(title: "Editing Basics", symbol: "slider.horizontal.3",
                  intro: "Start with the one-click fixes, then fine-tune with the sliders.",
                  sections: [
                    .init(heading: "One-click fixes", text: "Magic fix (⇧⌘M) corrects exposure, contrast and color together. Auto contrast and Auto color do one part each. The Neutral color picker removes a color cast when you click something that should be gray or white."),
                    .init(heading: "Crop, straighten and rotate", text: "Crop (⌥⌘C) offers common print shapes, and Suggest Crop frames the main subject. Straighten (⌥⌘T) levels a tilted horizon, or use Photo › Auto-Straighten. ⌘[ and ⌘] turn the photo."),
                    .init(heading: "Light, color and detail", text: "Sliders for exposure, highlights, shadows, warmth, saturation, sharpness, noise reduction and more. Double-click a slider to reset it. Curves, Levels and Color ranges give finer control."),
                    .init(heading: "Versions", text: "Save Version… in the editing panel keeps the current edits under a name, so you can try something different and switch back."),
                  ]),
        HelpTopic(title: "Retouching", symbol: "bandage",
                  intro: "Remove spots, unwanted objects and red eyes.",
                  sections: [
                    .init(heading: "Spot heal, clone, soften, remove", text: "Open Retouch (⌥⌘H) and pick a tool. Spot heal fills a blemish with nearby texture. Clone copies one area over another (⌥-click to choose the source first). Soften skin smooths gently. Remove fills a larger object from its surroundings and works best on simple backgrounds such as sky, grass or walls."),
                    .init(heading: "Red-eye", text: "Photo › Red-Eye finds and fixes red eyes from a flash. Click any it misses."),
                    .init(heading: "Tip", text: "Zoom in (⌘=) for small spots. Undo Last Stroke takes back the latest one."),
                  ]),
        HelpTopic(title: "Brushes, Gradients and Effects", symbol: "paintbrush.pointed",
                  intro: "Change just part of a photo, or give it a look.",
                  sections: [
                    .init(heading: "Brush and gradient", text: "Brush (⌥⌘G) paints exposure, contrast, saturation, warmth or blur onto part of the photo; hold ⌥ to erase. A gradient fades an adjustment across the photo, for example to darken a bright sky: drag from where it should be strongest to where it fades out."),
                    .init(heading: "Looks and presets", text: "The Effects section has one-click looks, each with its own strength. Save your favorite combination of settings as a preset and apply it to other photos, or to many at once from the Bulk menu."),
                    .init(heading: "Background blur and cutouts", text: "Blur background finds the subject and softens what's behind it. Remove Background… saves the subject alone as a PNG with a see-through background."),
                    .init(heading: "Tilt-shift, borders, text and shapes", text: "Tilt-shift makes a scene look like a tiny model. Border adds a plain, rounded or instant-print frame. Add Text (⌥⌘X) places captions; Shapes and Arrows (⌥⌘A) marks things up."),
                    .init(heading: "Lens correction", text: "Straightens lines that bow outward or inward and lines up colored fringes near the corners."),
                  ]),
        HelpTopic(title: "Organizing", symbol: "star",
                  intro: "Rate, tag and group photos without moving any files.",
                  sections: [
                    .init(heading: "Stars and flags", text: "In the grid or the editor, press 1–5 to rate, 0 to clear, P to mark a pick, X to reject and U to clear the flag. Rejected photos fade in the grid."),
                    .init(heading: "Tags", text: "Add tags in the Info panel (⌘I), for one photo or many. Settings can also save tags inside the photo files so other apps see them."),
                    .init(heading: "Albums", text: "Right-click photos › Add to Album, or Organize › New Album (⇧⌘N). Albums can hold photos from any folder, and still find a photo after it is moved in Finder."),
                    .init(heading: "Filter", text: "The Filter button shows only photos with enough stars, a pick or reject flag, or a tag."),
                    .init(heading: "People", text: "Fotolark finds faces in the background and groups them. In People, type a name under a group. Giving two groups the same name joins them; right-click a photo › Not This Person takes it out. If groups mix people, slide the setting toward Strictly."),
                    .init(heading: "Duplicates", text: "Organize › Find Duplicates… shows identical copies and photos that look nearly the same, keeps the best of each group and moves the others to the Trash after you confirm."),
                  ]),
        HelpTopic(title: "Searching and All Photos", symbol: "magnifyingglass",
                  intro: "Find any photo in your folders.",
                  sections: [
                    .init(heading: "Search", text: "Type in the search field at the top of the sidebar. Search looks at file and folder names, tags, keywords, the camera, dates (try “July 2024” or “2019”) and text in the photos, such as signs, documents and screenshots. Put words in quotes to match a phrase."),
                    .init(heading: "All Photos", text: "Every photo in your folders by month, newest first. Use it with the Filter button to see, for example, all your five-star photos."),
                  ]),
        HelpTopic(title: "Importing", symbol: "square.and.arrow.down",
                  intro: "Copy photos from a phone, camera, memory card, drive or Apple Photos into your folders.",
                  sections: [
                    .init(heading: "Phones, cameras and cards", text: "Plug in the device; it appears under Import in the sidebar. An iPhone must be unlocked and trust this Mac. Android phones show up only in “Transfer photos (PTP)” USB mode."),
                    .init(heading: "Choosing what to import", text: "Show only new photos or a date range, choose a folder, sort into date folders, rename as they come in, and convert HEIC to JPEG. Photos already imported are skipped. Deleting from the device after importing is off unless you turn it on, and only photos whose copies check out are deleted."),
                    .init(heading: "Apple Photos", text: "Choose Apple Photos under Import to copy photos or a whole album out of your Photos library into folders. Edit in Fotolark opens a picture for editing; Save to Photos (⌘S) puts the result back as a Photos edit, and Photos keeps the original."),
                  ]),
        HelpTopic(title: "Bulk Tools", symbol: "square.stack.3d.up",
                  intro: "Do the same thing to many photos at once.",
                  sections: [
                    .init(heading: "What's there", text: "Select photos, then use the Bulk menu: convert, resize, rename, rotate, move or copy (optionally into date folders), edit details such as dates and tags, and Magic fix or apply a preset. Each shows a preview first."),
                    .init(heading: "Jobs and undo", text: "Bulk jobs run in the background; the Jobs button shows progress, lets you pause or stop, lists anything skipped, and can undo a finished job."),
                    .init(heading: "Copy and paste edits", text: "Copy Edits (⇧⌘C) and Paste Edits (⇧⌘V) move tone, color and looks from one photo to others. One-click fixes are worked out again for each photo."),
                  ]),
        HelpTopic(title: "Sharing, Printing and PDFs", symbol: "printer",
                  intro: "Get your edited photos out of Fotolark.",
                  sections: [
                    .init(heading: "Export and share", text: "Export (⌘E) saves edited copies in JPEG, PNG, HEIC or TIFF, with size limits, watermarks and presets. The Share button sends them to Mail, Messages and more. Dragging photos out of the grid gives the edited version."),
                    .init(heading: "Print", text: "File › Print (⌘P) prints standard sizes (wallet, 4×6, 5×7, 8×10 or a full page), fitting several per page, or a page of copies of one photo."),
                    .init(heading: "Contact sheets, PDFs and collages", text: "File › Make Contact Sheet… lays out thumbnails with names. Export as PDF… combines photos into one PDF. Make Collage… arranges photos in a grid, a mosaic or as scattered prints."),
                    .init(heading: "Slideshow", text: "View › Start Slideshow (⌥⌘P) plays the photos full screen. Space pauses, the arrow keys move, Esc ends. Choose timing, transitions and music from the controls."),
                  ]),
        HelpTopic(title: "Where Your Edits Are Kept", symbol: "doc.badge.gearshape",
                  intro: "Fotolark never changes your original photos unless you ask it to.",
                  sections: [
                    .init(heading: "Sidecar files", text: "Each photo's edits, stars, tags and versions are saved in a small .fotolark file next to it (IMG_0001.jpg → IMG_0001.fotolark). Copy the folder and the edits come along. To keep folders tidy instead, choose Settings › General › Save edits: Inside Fotolark only."),
                    .init(heading: "When files do change", text: "Save Over Original replaces a photo with the edited version and keeps a backup (File › Show Backups in Finder). Bulk › Edit Details and saving tags into files rewrite only the stored details, never the picture, and also keep a backup."),
                  ]),
        HelpTopic(title: "Automation", symbol: "gearshape.2",
                  intro: "Let Fotolark do routine jobs for you.",
                  sections: [
                    .init(heading: "Watch folders", text: "In Settings › Watch Folders, choose a folder and what to do. Photos dropped into it are resized, converted or Magic-fixed into a “Fotolark” folder inside it, while Fotolark is open."),
                    .init(heading: "Finder", text: "Right-click photos in Finder › Services (or Quick Actions) › Resize with Fotolark or Quick Fix with Fotolark. If they don't appear, turn them on in System Settings › Keyboard › Keyboard Shortcuts › Services."),
                    .init(heading: "Shortcuts", text: "The Shortcuts app has Resize Photos, Convert Photos and Auto-Fix Photos actions from Fotolark. Each makes new files and leaves the originals alone."),
                  ]),
        HelpTopic(title: "Privacy", symbol: "lock.shield",
                  intro: "Everything Fotolark does happens on your Mac.",
                  sections: [
                    .init(heading: "Nothing leaves your Mac", text: "Face grouping, finding duplicates and reading text in photos all run on this Mac. Fotolark has no account, collects no data and doesn't contact any server. You can turn the background analysis off in Settings › General."),
                    .init(heading: "Access", text: "Fotolark can only see folders you add or open, and asks before it reads your Photos library."),
                  ]),
    ]
}

/// The first-run tour, also under Help › Welcome Tour.
struct WelcomeTour: View {
    @Bindable var model: AppModel
    @State private var page = 0
    @Environment(\.dismiss) private var dismiss

    private struct Page { let symbol: String; let title: String; let text: String }
    private let pages: [Page] = [
        Page(symbol: "photo.on.rectangle.angled", title: "Welcome to Fotolark",
             text: "A simple, fast way to see and fix the photos in your folders. Your originals are never changed: edits are kept beside each photo and can always be undone."),
        Page(symbol: "folder.badge.plus", title: "Start with your folders",
             text: "Add the folders where your photos already live. Fotolark shows them in the sidebar and keeps up with changes you make in Finder. Nothing is copied or moved."),
        Page(symbol: "wand.and.stars", title: "Fix a photo in seconds",
             text: "Double-click a photo, then try Magic fix. Crop, straighten, retouch and fine-tune with the sliders. Hold the \\ key to compare with the original."),
        Page(symbol: "star", title: "Keep the best ones close",
             text: "Press 1–5 to rate, P for a pick, X to reject. Make albums from any folders, search by what's in the photo, and let People group the faces it finds, all on this Mac."),
        Page(symbol: "square.and.arrow.up", title: "Share, print and import",
             text: "Export or share edited copies, print, make collages and slideshows, and import from your iPhone, camera, card or Apple Photos. Help › Fotolark Help explains everything."),
    ]

    var body: some View {
        VStack(spacing: 20) {
            let p = pages[page]
            Image(systemName: p.symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Color.accentColor)
                .frame(height: 70)
                .accessibilityHidden(true)
            Text(p.title).font(.title.weight(.semibold))
            Text(p.text)
                .font(.title3)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)
            HStack(spacing: 6) {
                ForEach(pages.indices, id: \.self) { i in
                    Circle().fill(i == page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(pages.count)")
            HStack {
                Button("Skip Tour") { finish() }.buttonStyle(.borderless)
                Spacer()
                if page > 0 { Button("Back") { page -= 1 } }
                if page == 1 && model.library.roots.isEmpty {
                    Button("Add a Folder…") { model.addFolderWithPanel() }
                }
                if page < pages.count - 1 {
                    Button("Next") { page += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { finish() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(width: 560, height: 420)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasSeenWelcomeTour")
        dismiss()
    }
}
