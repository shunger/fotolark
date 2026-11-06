import CoreImage
import Foundation
import Testing
@testable import FotolarkKit

@Suite("Duplicates and faces")
struct AnalysisTests {
    func photo(_ url: URL, modified: Date = Date(timeIntervalSince1970: 1000)) -> ScannedPhoto {
        ScannedPhoto(url: url, fileSize: 1, modified: modified, created: modified)
    }

    func fp(_ values: [Float]) -> Fingerprint { Fingerprint(values + Array(repeating: 0, count: 8)) }

    @Test func fingerprintsKeepTheirDistances() {
        let a: [Float] = (0..<768).map { sin(Float($0) * 0.1) * 0.05 }
        let b = a.enumerated().map { $0.offset % 7 == 0 ? $0.element + 0.02 : $0.element }
        let exact = sqrt(zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +))
        let stored = Fingerprint(a).distance(to: Fingerprint(b))
        #expect(abs(stored - exact) < 0.01, "\(stored) vs \(exact)")
        #expect(Fingerprint(a).values.count == 768, "one byte per value")
    }

    @Test func analyzerFingerprintsSamePictureAsClose() {
        var scene = CIImage(color: CIColor(red: 0.3, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 800, height: 600))
        for i in 0..<6 {
            let blob = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: CGFloat(97 + i * 131), y: CGFloat(53 + i * 71)),
                "inputRadius0": 30 + i * 8, "inputRadius1": 100 + i * 5,
                "inputColor0": CIColor(red: Double(i % 4) / 3, green: Double(i % 5) / 4, blue: 0.5),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])!.outputImage!
            scene = blob.composited(over: scene).cropped(to: scene.extent)
        }
        let a = PhotoAnalyzer.analyze(scene, context: testEngine.context)!
        let b = PhotoAnalyzer.analyze(scene.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5)), context: testEngine.context)!
        #expect(a.faces.isEmpty)
        #expect(a.fingerprint!.distance(to: b.fingerprint!) < DuplicateFinder.similarThreshold)
    }

    @Test func exactDuplicatesMatchByContent() throws {
        let dir = try makeTempDirectory()
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg"), c = dir.appendingPathComponent("c.jpg")
        try writePhoto(Grid.numbered(width: 5, height: 4), to: a)
        try FileManager.default.copyItem(at: a, to: b)
        try writePhoto(Grid.numbered(width: 5, height: 4).rotatedClockwise(), to: c)
        let photos = PhotoScanner.photos(in: dir)
        let groups = DuplicateFinder.exactGroups(photos)
        #expect(groups.map { $0.map(\.lastPathComponent) } == [["a.jpg", "b.jpg"]])
    }

    @Test func similarGroupsOnlyCompareNearbyPhotos() throws {
        let dir = try makeTempDirectory()
        let store = AnalysisStore(fileURL: dir.appendingPathComponent("A.plist"))
        let urls = (0..<5).map { dir.appendingPathComponent("\($0).jpg") }
        let photos = urls.enumerated().map { photo($1, modified: Date(timeIntervalSince1970: Double($0))) }
        let near: [Float] = [1, 0, 0], alsoNear: [Float] = [0.95, 0.05, 0], far: [Float] = [0, 1, 0]
        for (p, v) in zip(photos, [near, alsoNear, far, near, far]) {
            store.set(PhotoAnalysis(fingerprint: fp(v), faces: []), for: p)
        }
        let dates = Dictionary(uniqueKeysWithValues: photos.map { ($0.url, $0.created) })
        let groups = DuplicateFinder.similarGroups(photos, dates: dates, store: store)
        #expect(groups.count == 2)
        #expect(Set(groups.flatMap { $0 }.map(\.lastPathComponent)) == ["0.jpg", "1.jpg", "3.jpg", "2.jpg", "4.jpg"])
        // With a window of one neighbour, photo 3 is too far from 0 and 1 to be compared.
        let narrow = DuplicateFinder.similarGroups(photos, dates: dates, store: store, window: 1)
        #expect(narrow.map { Set($0.map(\.lastPathComponent)) } == [["0.jpg", "1.jpg"]])

        store.save()
        #expect(AnalysisStore(fileURL: dir.appendingPathComponent("A.plist")).analysis(for: photos[0])?.fingerprint == fp(near))
        #expect(store.analysis(for: photo(urls[0], modified: Date())) == nil, "changed photo needs a new look")
    }

    @Test func facesGroupNameAndJoin() throws {
        let dir = try makeTempDirectory()
        let people = PeopleStore(fileURL: dir.appendingPathComponent("People.json"))
        func face(_ v: [Float]) -> FaceInfo { FaceInfo(x: 0, y: 0, width: 0.1, height: 0.1, fingerprint: fp(v)) }
        let url = dir.appendingPathComponent("p.jpg")
        let ann = [face([1, 0, 0]), face([0.97, 0.03, 0]), face([0.98, 0, 0.02])]
        let bob = [face([0, 1, 0]), face([0, 0.96, 0.04])]
        let all = (ann + bob).map { (photo: url, face: $0) }
        var groups = people.groups(all)
        #expect(groups.map(\.faces.count) == [3, 2])
        #expect(groups.allSatisfy { $0.person == nil })

        let annPerson = people.name(groups[0].faces.map(\.face.id), as: "Ann")
        // A new face like Ann's joins her automatically.
        let newAnn = face([0.99, 0.01, 0])
        groups = people.groups(all + [(url, newAnn)])
        #expect(groups.first?.person == annPerson)
        #expect(groups.first?.faces.count == 4)

        // Naming a second group with the same name joins them; "not this person" sticks.
        people.name([bob[0].id], as: "ann")
        #expect(people.people.count == 1)
        people.remove(bob[0].id)
        groups = PeopleStore(fileURL: dir.appendingPathComponent("People.json")).groups(all)
        #expect(!groups.flatMap(\.faces).contains { $0.face.id == bob[0].id })
    }
}
