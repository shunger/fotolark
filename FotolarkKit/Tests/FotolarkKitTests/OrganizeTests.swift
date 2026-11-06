import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FotolarkKit

@Suite("Ratings, flags, tags and albums")
struct OrganizeTests {
    func jpeg(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, Grid.numbered(width: 4, height: 3).cgImage, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func labelsClampAndTagsIgnoreCase() {
        var l = PhotoLabels(rating: 9, tags: ["Beach", " beach ", "", "Family"])
        #expect(l.rating == 5)
        #expect(l.tags == ["Beach", "Family"])
        l.rating = -2
        #expect(l.rating == 0)
        let added = l.addTag("FAMILY")
        #expect(!added)
        l.removeTag("family")
        #expect(l.tags == ["Beach"])
        #expect(!l.isEmpty)
        #expect(PhotoLabels().isEmpty)
    }

    @Test func labelsAndEditsShareTheSidecarWithoutClobbering() throws {
        let dir = try makeTempDirectory()
        let photo = try jpeg("a.jpg", in: dir)
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library"))

        try store.saveLabels(PhotoLabels(rating: 4, flag: .pick, tags: ["Trip"]), for: photo)
        let recipe = EditRecipe().setting(.straighten(degrees: 2))
        try store.save(recipe, for: photo)
        #expect(store.loadLabels(for: photo) == PhotoLabels(rating: 4, flag: .pick, tags: ["Trip"]))
        #expect(store.load(for: photo) == recipe)

        // Clearing the edits keeps the rating, and the sidecar with it.
        try store.save(EditRecipe(), for: photo)
        #expect(store.load(for: photo) == nil)
        #expect(store.loadLabels(for: photo).rating == 4)
        #expect(FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: photo).path))

        // Clearing both removes the sidecar.
        try store.saveLabels(PhotoLabels(), for: photo)
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: photo).path))
    }

    @Test func olderSidecarsWithoutLabelsStillLoad() throws {
        let dir = try makeTempDirectory()
        let photo = try jpeg("old.jpg", in: dir)
        let json = #"{"format":"Fotolark edits","version":1,"photos":{"old.jpg":{"version":1,"operations":[{"op":"straighten","value":3}]}}}"#
        try Data(json.utf8).write(to: RecipeStore.sidecarURL(for: photo))
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library"))
        #expect(store.load(for: photo)?.straightenDegrees == 3)
        #expect(store.loadLabels(for: photo).isEmpty)
        // A sidecar with no labels is written without a "labels" key.
        try store.save(EditRecipe().setting(.straighten(degrees: 1)), for: photo)
        let text = try String(contentsOf: RecipeStore.sidecarURL(for: photo), encoding: .utf8)
        #expect(!text.contains("labels"))
    }

    @Test func labelsFollowRenamesMovesAndCopies() throws {
        let dir = try makeTempDirectory()
        let photo = try jpeg("b.jpg", in: dir)
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library"))
        try store.saveLabels(PhotoLabels(rating: 3, tags: ["Dog"]), for: photo)
        let ops = PhotoFileOperations(store: store)

        let renamed = try ops.rename(photo, to: "c")
        #expect(store.loadLabels(for: renamed).rating == 3)
        #expect(store.loadLabels(for: photo).isEmpty)

        let sub = dir.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let copy = try ops.copy([renamed], to: sub)[0]
        #expect(store.loadLabels(for: copy).tags == ["Dog"])

        // Bulk rename (two-step) carries labels too, and so does its undo.
        let item = RenamePreviewItem(source: renamed, newName: "d.jpg", problem: nil)
        let result = RenamePlan.apply([item], store: store)
        let d = dir.appendingPathComponent("d.jpg")
        #expect(store.loadLabels(for: d).rating == 3)
        #expect(BulkRunner.undo(result.undo, store: store).isEmpty)
        #expect(store.loadLabels(for: renamed).rating == 3)
        #expect(store.loadLabels(for: d).isEmpty)
    }

    @Test func libraryModeKeepsLabelsOutOfTheFolder() throws {
        let dir = try makeTempDirectory()
        let photo = try jpeg("e.jpg", in: dir)
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library"))
        try store.save(EditRecipe().setting(.straighten(degrees: 2)), for: photo)
        store.usesSidecars = false
        try store.saveLabels(PhotoLabels(rating: 5), for: photo)
        #expect(!FileManager.default.fileExists(atPath: RecipeStore.sidecarURL(for: photo).path))
        #expect(store.loadRecord(for: photo) == PhotoRecord(recipe: EditRecipe().setting(.straighten(degrees: 2)),
                                                            labels: PhotoLabels(rating: 5)))
        #expect(store.records(for: [photo])[photo]?.labels.rating == 5)
    }

    @Test func recordsForAFolderIncludeLabelOnlyPhotos() throws {
        let dir = try makeTempDirectory()
        let a = try jpeg("f.jpg", in: dir), b = try jpeg("g.jpg", in: dir), c = try jpeg("h.jpg", in: dir)
        let store = RecipeStore(fallbackDirectory: dir.appendingPathComponent("Library"))
        try store.saveLabels(PhotoLabels(flag: .reject), for: a)
        try store.save(EditRecipe().setting(.straighten(degrees: 1)), for: b)
        let records = store.records(for: [a, b, c])
        #expect(records[a]?.labels.flag == .reject)
        #expect(records[b]?.labels.isEmpty == true)
        #expect(records[c] == nil)
        #expect(store.recipes(for: [a, b, c]).keys.sorted { $0.path < $1.path } == [b])
    }

    @Test func albumsKeepPhotosAcrossFoldersAndFindMovedOnes() throws {
        let dir = try makeTempDirectory()
        let a = try jpeg("i.jpg", in: dir)
        let other = dir.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let b = try jpeg("j.jpg", in: other)
        let file = dir.appendingPathComponent("Albums.json")
        let albums = AlbumStore(fileURL: file)
        let trip = albums.create(named: "  Trip ", with: [a])
        #expect(trip.name == "Trip")
        albums.add([a, b], to: trip.id)
        #expect(albums.photos(in: trip.id) == [a, b].map(\.standardizedFileURL))

        // Moved in Finder: found again by its bookmark, and remembered there.
        let moved = dir.appendingPathComponent("moved.jpg")
        try FileManager.default.moveItem(at: b, to: moved)
        #expect(albums.photos(in: trip.id).map(\.lastPathComponent) == ["i.jpg", "moved.jpg"])
        let reloaded = AlbumStore(fileURL: file)
        #expect(reloaded.album(trip.id)?.items.last?.path == moved.standardizedFileURL.path)

        albums.remove([a], from: trip.id)
        #expect(albums.photos(in: trip.id).count == 1)
        albums.rename(trip.id, to: "Summer")
        #expect(AlbumStore(fileURL: file).album(trip.id)?.name == "Summer")
        albums.delete(trip.id)
        #expect(AlbumStore(fileURL: file).albums.isEmpty)
    }

    @Test func keywordsCanBeRemovedFromTheFile() throws {
        let dir = try makeTempDirectory()
        let photo = try jpeg("k.jpg", in: dir)
        var add = MetadataChanges()
        add.addKeywords = ["Beach", "Dog"]
        _ = try MetadataEditor.apply(add, to: photo, backupDirectory: dir.appendingPathComponent("Backups"))
        #expect(PhotoMetadata.read(photo).keywords == ["Beach", "Dog"])
        var remove = MetadataChanges()
        remove.removeKeywords = ["beach"]
        _ = try MetadataEditor.apply(remove, to: photo, backupDirectory: dir.appendingPathComponent("Backups"))
        #expect(PhotoMetadata.read(photo).keywords == ["Dog"])
        remove.removeKeywords = ["Dog"]
        _ = try MetadataEditor.apply(remove, to: photo, backupDirectory: dir.appendingPathComponent("Backups"))
        #expect(PhotoMetadata.read(photo).keywords.isEmpty)
    }
}
