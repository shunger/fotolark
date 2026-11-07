import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FotolarkKit

@Suite("Import")
struct ImportTests {
    let date = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!

    func candidate(_ file: URL, name: String? = nil, type: UTType = .jpeg) -> ImportCandidate {
        let size = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return ImportCandidate(id: file.path, name: name ?? file.lastPathComponent, fileSize: size, date: date,
                               typeIdentifier: type.identifier)
    }

    @Test func videosAreLeftOutAndHEICIsRecognized() {
        let video = ImportCandidate(id: "1", name: "IMG_1.MOV", fileSize: 1, date: nil, typeIdentifier: UTType.quickTimeMovie.identifier)
        let heic = ImportCandidate(id: "2", name: "IMG_2.HEIC", fileSize: 1, date: nil, typeIdentifier: nil)
        #expect(!video.isPhoto)
        #expect(heic.isPhoto && heic.isHEIC)
    }

    @Test func placesIntoDateFoldersWithNewNameAndVerifies() throws {
        let dir = try makeTempDirectory()
        let device = try makePhotos(["IMG_0001.JPG"], in: dir)[0]
        let downloaded = dir.appendingPathComponent("download.tmp")
        try FileManager.default.copyItem(at: device, to: downloaded)
        var options = ImportOptions()
        options.dateFolders = DateFolderPattern(style: .yearThenDay, eventName: "Beach")
        var rule = RenameRule()
        rule.pattern = "Beach-{number}"
        rule.lowercaseExtension = true
        options.rename = rule
        let root = dir.appendingPathComponent("Pictures")
        let c = candidate(device)
        let placed = try Importer.place(downloaded, candidate: c, index: 0, options: options, root: root, engine: testEngine)
        let local = DateFormatter(); local.dateFormat = "yyyy-MM-dd"
        #expect(placed.files.map(\.path) == [root.appendingPathComponent("2026/\(local.string(from: date)) Beach/Beach-001.jpg").path])
        #expect(placed.verified)
    }

    @Test func convertsHEICAndCanKeepTheOriginal() throws {
        let dir = try makeTempDirectory()
        let heic = dir.appendingPathComponent("IMG_2.heic")
        try writePhoto(Grid.numbered(width: 4, height: 4), to: heic, type: .heic)
        for keep in [true, false] {
            let downloaded = dir.appendingPathComponent("dl-\(keep).tmp")
            try FileManager.default.copyItem(at: heic, to: downloaded)
            var options = ImportOptions()
            options.convertHEICToJPEG = true
            options.keepHEICOriginal = keep
            let root = dir.appendingPathComponent("out-\(keep)")
            let placed = try Importer.place(downloaded, candidate: candidate(heic, type: .heic), index: 0,
                                            options: options, root: root, engine: testEngine)
            #expect(placed.files.map(\.lastPathComponent) == (keep ? ["IMG_2.jpg", "IMG_2.heic"] : ["IMG_2.jpg"]))
            #expect(placed.verified)
        }
    }

    @Test func duplicatesByHistoryOrExistingFile() throws {
        let dir = try makeTempDirectory()
        let device = try makePhotos(["IMG_9.jpg"], in: dir)[0]
        let history = ImportHistory(fileURL: dir.appendingPathComponent("history.json"))
        let root = dir.appendingPathComponent("dest")
        let c = candidate(device)
        #expect(!Importer.isDuplicate(c, index: 0, options: ImportOptions(), root: root, history: history))
        // Already in the destination with the same size.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: device, to: root.appendingPathComponent("IMG_9.jpg"))
        #expect(Importer.isDuplicate(c, index: 0, options: ImportOptions(), root: root, history: history))
        // Remembered across launches.
        let other = dir.appendingPathComponent("elsewhere")
        history.insert(c)
        history.save()
        let reloaded = ImportHistory(fileURL: dir.appendingPathComponent("history.json"))
        #expect(Importer.isDuplicate(c, index: 0, options: ImportOptions(), root: other, history: reloaded))
    }

    @Test func badCopyIsNotVerified() throws {
        let dir = try makeTempDirectory()
        let device = try makePhotos(["IMG_5.jpg"], in: dir)[0]
        let downloaded = dir.appendingPathComponent("broken.tmp")
        try Data("not a photo".utf8).write(to: downloaded)
        let placed = try Importer.place(downloaded, candidate: candidate(device), index: 0, options: ImportOptions(),
                                        root: dir.appendingPathComponent("dest"), engine: testEngine)
        #expect(!placed.verified, "a copy that doesn't match must never allow deleting the original")
    }
}

@Suite("HEIC from devices that report odd types")
struct DeviceTypeTests {
    @Test func heicIsRecognizedByNameOrContents() throws {
        for uti in [nil, "public.image", "public.data", "com.example.unknown", "public.heic"] as [String?] {
            let c = ImportCandidate(id: "1", name: "IMG_1.HEIC", fileSize: 0, date: nil, typeIdentifier: uti)
            #expect(c.isHEIC, "\(uti ?? "nil")")
            #expect(c.isPhoto, "\(uti ?? "nil")")
        }
        let jpg = ImportCandidate(id: "2", name: "IMG_2.JPG", fileSize: 0, date: nil, typeIdentifier: "public.image")
        #expect(!jpg.isHEIC && jpg.isPhoto)
    }

    @Test func convertsHEICEvenWhenTheDeviceDidNotSaySo() throws {
        let dir = try makeTempDirectory()
        let downloaded = dir.appendingPathComponent("dl.heic")
        try writePhoto(Grid.numbered(width: 5, height: 4), to: downloaded, type: .heic)
        // Name without .heic and a vague type: only the contents say it's HEIC.
        let c = ImportCandidate(id: "x", name: "IMG_7.photo", fileSize: 0, date: nil, typeIdentifier: "public.data")
        var options = ImportOptions()
        options.convertHEICToJPEG = true
        options.keepHEICOriginal = true
        let placed = try Importer.place(downloaded, candidate: c, index: 0, options: options,
                                        root: dir.appendingPathComponent("Out"), engine: testEngine)
        #expect(placed.files.map(\.pathExtension) == ["jpg", "photo"])
        #expect(placed.verified)
    }
}

@Suite("Import screen date groups")
struct ImportGroupTests {
    func c(_ name: String, _ iso: String?) -> ImportCandidate {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return ImportCandidate(id: name, name: name, fileSize: 1, date: iso.flatMap { f.date(from: $0) }, typeIdentifier: "public.jpeg")
    }

    var utc: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test func groupsByMonthNewestFirstWithUndatedLast() {
        let items = [c("a", "2020-03-14T10:00:00Z"), c("b", nil), c("c", "2021-07-01T09:00:00Z"),
                     c("d", "2020-03-02T08:00:00Z"), c("e", "2020-04-01T00:30:00Z")]
        let g = Importer.groups(items, by: .month, calendar: utc)
        #expect(g.map { $0.items.map(\.name) } == [["c"], ["e"], ["a", "d"], ["b"]])
        #expect(g.last?.title == "No date")
        #expect(g[2].title.contains("2020"))
    }

    @Test func groupsByDayAndNotAtAll() {
        let items = [c("a", "2020-03-14T10:00:00Z"), c("b", "2020-03-14T23:00:00Z"), c("c", "2020-03-15T01:00:00Z")]
        #expect(Importer.groups(items, by: .day, calendar: utc).map(\.items.count) == [1, 2])
        let none = Importer.groups(items, by: .none, calendar: utc)
        #expect(none.count == 1 && none[0].items.count == 3)
        #expect(Importer.groups([], by: .month).isEmpty)
    }
}
