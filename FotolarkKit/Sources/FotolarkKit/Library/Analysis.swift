import Accelerate
import CoreImage
import CryptoKit
import Foundation
import Vision

/// A compact numeric fingerprint of what a picture (or a face) looks like, from Vision.
/// Similar pictures have fingerprints a short distance apart. Stored as 8-bit values to
/// keep the cache small.
public struct Fingerprint: Codable, Equatable, Sendable {
    public var values: Data
    public var scale: Float

    public init(_ floats: [Float]) {
        let peak = max(floats.map(abs).max() ?? 1, 1e-6)
        scale = peak / 127
        values = Data(floats.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 / peak * 127).rounded())))) })
    }

    public var floats: [Float] {
        values.map { Float(Int8(bitPattern: $0)) * scale }
    }

    /// Straight-line distance between two fingerprints (0 = identical).
    public func distance(to other: Fingerprint) -> Float {
        let a = floats, b = other.floats
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return sqrt(vDSP.distanceSquared(a, b))
    }
}

/// A face found in a photo.
public struct FaceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Normalized, top-left origin, on the photo as taken (camera orientation applied).
    public var x, y, width, height: Double
    public var fingerprint: Fingerprint

    public init(id: UUID = UUID(), x: Double, y: Double, width: Double, height: Double, fingerprint: Fingerprint) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.fingerprint = fingerprint
    }
}

/// What Vision found in one photo.
public struct PhotoAnalysis: Codable, Equatable, Sendable {
    public var fingerprint: Fingerprint?
    public var faces: [FaceInfo]

    public init(fingerprint: Fingerprint?, faces: [FaceInfo]) {
        self.fingerprint = fingerprint
        self.faces = faces
    }
}

public enum PhotoAnalyzer {
    /// Looks at a photo: its overall fingerprint, and each face with its own fingerprint.
    public static func analyze(_ url: URL, context: CIContext) -> PhotoAnalysis? {
        guard let image = try? ImageLoader.loadPreview(url, maxPixelSize: 1024) else { return nil }
        return analyze(image, context: context)
    }

    public static func analyze(_ image: CIImage, context: CIContext) -> PhotoAnalysis? {
        let img = image.normalizedToOrigin()
        guard let cg = context.createCGImage(img, from: img.extent) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let print = VNGenerateImageFeaturePrintRequest()
        let faces = VNDetectFaceRectanglesRequest()
        try? handler.perform([print, faces])
        let overall = (print.results?.first).flatMap(fingerprint(of:))

        var found: [FaceInfo] = []
        for face in faces.results ?? [] where face.boundingBox.width * img.extent.width >= 40 {
            // A square around the face with a little room, turned upright.
            let b = face.boundingBox
            let side = max(b.width * img.extent.width, b.height * img.extent.height) * 1.3
            let center = CGPoint(x: b.midX * img.extent.width, y: b.midY * img.extent.height)
            var crop = img.cropped(to: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
            if let roll = face.roll?.doubleValue, abs(roll) > 0.05 {
                crop = crop.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y)
                    .concatenating(CGAffineTransform(rotationAngle: -roll))
                    .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
                    .cropped(to: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
            }
            guard let faceCG = context.createCGImage(crop, from: crop.extent) else { continue }
            let request = VNGenerateImageFeaturePrintRequest()
            try? VNImageRequestHandler(cgImage: faceCG, options: [:]).perform([request])
            guard let fp = (request.results?.first).flatMap(fingerprint(of:)) else { continue }
            found.append(FaceInfo(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height, fingerprint: fp))
        }
        return PhotoAnalysis(fingerprint: overall, faces: found)
    }

    static func fingerprint(of o: VNFeaturePrintObservation) -> Fingerprint? {
        guard o.elementType == .float else { return nil }
        let floats = o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(o.elementCount)) }
        return Fingerprint(floats)
    }
}

/// Analysis results for every photo, kept between launches (as a compact binary file).
public final class AnalysisStore: @unchecked Sendable {
    struct Entry: Codable {
        var modified: Date
        var analysis: PhotoAnalysis
    }

    private var entries: [String: Entry]
    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        entries = (try? PropertyListDecoder().decode([String: Entry].self, from: Data(contentsOf: fileURL))) ?? [:]
    }

    public func analysis(for photo: ScannedPhoto) -> PhotoAnalysis? {
        lock.withLock {
            guard let e = entries[photo.url.standardizedFileURL.path], e.modified == photo.modified else { return nil }
            return e.analysis
        }
    }

    public func set(_ analysis: PhotoAnalysis, for photo: ScannedPhoto) {
        lock.withLock { entries[photo.url.standardizedFileURL.path] = Entry(modified: photo.modified, analysis: analysis) }
    }

    public func needsAnalysis(_ photos: [ScannedPhoto]) -> [ScannedPhoto] {
        photos.filter { analysis(for: $0) == nil }
    }

    /// Every face, with the photo it's in.
    public func allFaces(in photos: [ScannedPhoto]) -> [(photo: URL, face: FaceInfo)] {
        photos.flatMap { p in (analysis(for: p)?.faces ?? []).map { (p.url, $0) } }
    }

    /// Forgets photos that are no longer in `keep`.
    public func prune(keeping keep: Set<String>) {
        lock.withLock { entries = entries.filter { keep.contains($0.key) } }
    }

    public func save() {
        let data = lock.withLock { () -> Data? in
            let e = PropertyListEncoder()
            e.outputFormat = .binary
            return try? e.encode(entries)
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Duplicates

public enum DuplicateFinder {
    /// Groups of identical files (same size, then same contents), biggest groups first.
    public static func exactGroups(_ photos: [ScannedPhoto], isCancelled: () -> Bool = { false }) -> [[URL]] {
        let bySize = Dictionary(grouping: photos) { $0.fileSize }.values.filter { $0.count > 1 }
        var groups: [[URL]] = []
        for same in bySize {
            if isCancelled() { return groups }
            let byHash = Dictionary(grouping: same) { hash($0.url) ?? UUID().uuidString }
            groups += byHash.values.filter { $0.count > 1 }.map { $0.map(\.url).sorted { $0.path < $1.path } }
        }
        return groups.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0].path < $1[0].path }
    }

    static func hash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Distance below which two photos count as near-duplicates (the same shot, resized,
    /// recompressed or lightly edited, or a burst of almost the same moment). Measured:
    /// a resized copy ≈ 0.05, brightened ≈ 0.09, slightly cropped ≈ 0.14; different
    /// (even similar-looking) pictures ≥ 0.3.
    public static let similarThreshold: Float = 0.25

    /// Groups of photos that look nearly the same. Only photos taken close together (in
    /// `dates` order, within `window` photos of each other) are compared, which finds
    /// bursts and re-saved copies without comparing every pair in a big library.
    public static func similarGroups(_ photos: [ScannedPhoto], dates: [URL: Date], store: AnalysisStore,
                                     threshold: Float = similarThreshold, window: Int = 25) -> [[URL]] {
        let sorted = photos
            .compactMap { p in store.analysis(for: p)?.fingerprint.map { (p, $0) } }
            .sorted { (dates[$0.0.url] ?? $0.0.created) < (dates[$1.0.url] ?? $1.0.created) }
        var parent = Array(sorted.indices)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in sorted.indices {
            for j in (i + 1)..<min(i + 1 + window, sorted.count) where sorted[i].1.distance(to: sorted[j].1) < threshold {
                parent[find(j)] = find(i)
            }
        }
        let groups = Dictionary(grouping: sorted.indices, by: find).values.filter { $0.count > 1 }
        return groups.map { $0.map { sorted[$0].0.url } }.sorted { $0.count > $1.count }
    }

    /// Which photo of a group to keep: the most pixels, then edited, then the biggest file.
    public static func best(of group: [URL], edited: Set<URL> = []) -> URL? {
        group.max { a, b in
            let pa = (try? ImageLoader.info(for: a)).map { $0.pixelSize.width * $0.pixelSize.height } ?? 0
            let pb = (try? ImageLoader.info(for: b)).map { $0.pixelSize.width * $0.pixelSize.height } ?? 0
            if pa != pb { return pa < pb }
            if edited.contains(a) != edited.contains(b) { return edited.contains(b) }
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
    }
}

// MARK: - People

/// A named person; faces are linked to people in `PeopleStore`.
public struct Person: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// A group of faces that look like the same person.
public struct FaceGroup: Identifiable, Sendable {
    public var id: UUID { faces[0].face.id }
    public var faces: [(photo: URL, face: FaceInfo)]
    /// Set when the group's faces were named.
    public var person: Person?
}

/// Named people and which faces are theirs (or were marked "not this person"),
/// saved in Fotolark's own storage. Faces never leave the Mac.
public final class PeopleStore: @unchecked Sendable {
    struct Saved: Codable {
        var people: [Person] = []
        /// Face id → person id.
        var assigned: [UUID: UUID] = [:]
        /// Faces taken out of a group by hand ("not this person"), never auto-matched again.
        var ignored: Set<UUID> = []
    }

    private var saved: Saved
    private let lock = NSLock()
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        saved = (try? JSONDecoder().decode(Saved.self, from: Data(contentsOf: fileURL))) ?? Saved()
    }

    public var people: [Person] { lock.withLock { saved.people }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    public func person(for face: UUID) -> Person? {
        lock.withLock { saved.assigned[face].flatMap { id in saved.people.first { $0.id == id } } }
    }

    /// Names faces. An existing person with the same name gets them (this is how two
    /// groups of the same person are joined).
    @discardableResult
    public func name(_ faces: [UUID], as name: String) -> Person {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let person = lock.withLock { () -> Person in
            let p = saved.people.first { $0.name.caseInsensitiveCompare(clean) == .orderedSame } ?? {
                let p = Person(name: clean)
                saved.people.append(p)
                return p
            }()
            for f in faces { saved.assigned[f] = p.id; saved.ignored.remove(f) }
            return p
        }
        save()
        return person
    }

    public func rename(_ id: Person.ID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lock.withLock { if let i = saved.people.firstIndex(where: { $0.id == id }) { saved.people[i].name = clean } }
        save()
    }

    /// "Not this person": the face leaves its group and isn't matched automatically again.
    public func remove(_ face: UUID) {
        lock.withLock { saved.assigned[face] = nil; saved.ignored.insert(face) }
        save()
    }

    public func delete(_ id: Person.ID) {
        lock.withLock {
            saved.people.removeAll { $0.id == id }
            saved.assigned = saved.assigned.filter { $0.value != id }
        }
        save()
    }

    /// Faces closer than this are taken to be the same person. Kept strict: two groups
    /// of one person are easy to join by naming both the same; one group mixing two
    /// people is annoying to split.
    /// Not yet tuned on real faces; the People view lets the person adjust it.
    public static let sameFaceThreshold: Float = 0.4

    /// Named people's faces, plus unnamed faces grouped by likeness. An unnamed face that
    /// closely matches a named person's faces joins that person.
    public func groups(_ faces: [(photo: URL, face: FaceInfo)], threshold: Float = sameFaceThreshold) -> [FaceGroup] {
        let s = lock.withLock { saved }
        var named: [UUID: [(URL, FaceInfo)]] = [:]
        var loose: [(URL, FaceInfo)] = []
        for item in faces {
            if let pid = s.assigned[item.face.id], s.people.contains(where: { $0.id == pid }) {
                named[pid, default: []].append(item)
            } else if !s.ignored.contains(item.face.id) {
                loose.append(item)
            }
        }
        // Unnamed faces close to a named person's faces join them.
        var stillLoose: [(URL, FaceInfo)] = []
        for item in loose {
            var best: (UUID, Float)?
            for (pid, list) in named {
                let d = list.prefix(20).map { $0.1.fingerprint.distance(to: item.1.fingerprint) }.min() ?? .infinity
                if d < threshold * 0.85, d < (best?.1 ?? .infinity) { best = (pid, d) }
            }
            if let best { named[best.0, default: []].append(item) } else { stillLoose.append(item) }
        }
        // The rest: each face joins the closest group within the threshold (single link).
        var clusters: [[(URL, FaceInfo)]] = []
        for item in stillLoose {
            var bestIndex: Int?
            var bestDistance = threshold
            for (i, c) in clusters.enumerated() {
                let d = c.map { $0.1.fingerprint.distance(to: item.1.fingerprint) }.min() ?? .infinity
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            if let bestIndex { clusters[bestIndex].append(item) } else { clusters.append([item]) }
        }
        let people = Dictionary(uniqueKeysWithValues: s.people.map { ($0.id, $0) })
        let namedGroups = named.compactMap { pid, list in
            people[pid].map { FaceGroup(faces: list.map { (photo: $0.0, face: $0.1) }, person: $0) }
        }.sorted { $0.person!.name.localizedStandardCompare($1.person!.name) == .orderedAscending }
        let unnamed = clusters.map { FaceGroup(faces: $0.map { (photo: $0.0, face: $0.1) }, person: nil) }
            .sorted { $0.faces.count > $1.faces.count }
        return namedGroups + unnamed
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder().encode(saved) }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data?.write(to: fileURL, options: .atomic)
    }
}
