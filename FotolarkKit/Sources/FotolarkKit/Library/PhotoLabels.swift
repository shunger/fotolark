import Foundation

/// How a photo is organized: its star rating, pick/reject flag and tags. Kept with the
/// photo's edits (in its sidecar), so it travels with the photo.
public struct PhotoLabels: Codable, Equatable, Hashable, Sendable {
    public enum Flag: String, Codable, CaseIterable, Sendable {
        case none, pick, reject
    }

    /// 0 (no stars) to 5.
    public var rating: Int {
        didSet { rating = min(max(rating, 0), 5) }
    }
    public var flag: Flag
    /// In the order they were added; never two that differ only in capitalization.
    public private(set) var tags: [String]

    public init(rating: Int = 0, flag: Flag = .none, tags: [String] = []) {
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        self.tags = []
        for t in tags { addTag(t) }
    }

    public var isEmpty: Bool { rating == 0 && flag == .none && tags.isEmpty }

    /// Adds a tag (trimmed). Returns false if it was empty or already there.
    @discardableResult
    public mutating func addTag(_ tag: String) -> Bool {
        let t = Self.clean(tag)
        guard !t.isEmpty, !hasTag(t) else { return false }
        tags.append(t)
        return true
    }

    public mutating func removeTag(_ tag: String) {
        let t = Self.clean(tag)
        tags.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
    }

    public func hasTag(_ tag: String) -> Bool {
        let t = Self.clean(tag)
        return tags.contains { $0.caseInsensitiveCompare(t) == .orderedSame }
    }

    static func clean(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).joined(separator: " ")
    }

    // Defaults are left out of the file to keep sidecars small.
    enum CodingKeys: String, CodingKey { case rating, flag, tags }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(rating: try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0,
                  flag: (try? c.decodeIfPresent(Flag.self, forKey: .flag)) ?? Flag.none,
                  tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if rating != 0 { try c.encode(rating, forKey: .rating) }
        if flag != .none { try c.encode(flag, forKey: .flag) }
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
    }
}

/// Everything Fotolark keeps about one photo: its edits and how it's organized.
public struct PhotoRecord: Equatable, Sendable {
    public var recipe: EditRecipe
    public var labels: PhotoLabels
    /// Named versions of the edits, oldest first.
    public var versions: [EditVersion]

    public init(recipe: EditRecipe = EditRecipe(), labels: PhotoLabels = PhotoLabels(), versions: [EditVersion] = []) {
        self.recipe = recipe
        self.labels = labels
        self.versions = versions
    }

    public var isEmpty: Bool { recipe.isEmpty && labels.isEmpty && versions.isEmpty }
}

/// A change to several photos' ratings, flags or tags at once.
public enum LabelChange: Equatable, Sendable {
    case rating(Int)
    case flag(PhotoLabels.Flag)
    case addTag(String)
    case removeTag(String)

    public func apply(to labels: inout PhotoLabels) {
        switch self {
        case .rating(let r): labels.rating = r
        case .flag(let f): labels.flag = f
        case .addTag(let t): labels.addTag(t)
        case .removeTag(let t): labels.removeTag(t)
        }
    }
}
