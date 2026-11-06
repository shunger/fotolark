import Foundation

/// How a slideshow plays.
public struct SlideshowSettings: Codable, Equatable, Sendable {
    public enum Transition: String, Codable, CaseIterable, Identifiable, Sendable {
        case crossfade, slide, kenBurns, none

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .crossfade: "Crossfade"
            case .slide: "Slide"
            case .kenBurns: "Slow Zoom"
            case .none: "None"
            }
        }
    }

    /// Seconds each photo stays on screen.
    public var seconds: Double = 4
    public var transition = Transition.crossfade
    public var shuffle = false
    /// Start again after the last photo.
    public var loop = true
    /// Music to play (a bookmark to an audio file the person chose), if any.
    public var musicBookmark: Data?
    public var musicName: String?

    public init() {}

    public static let durations: [Double] = [2, 3, 4, 6, 8, 12]

    /// The order to show `count` photos in, starting with `start`. Shuffled orders still
    /// begin with the photo the person started from.
    public func order(count: Int, start: Int, seed: UInt64 = .random(in: 1...UInt64.max)) -> [Int] {
        guard count > 0 else { return [] }
        let first = min(max(start, 0), count - 1)
        guard shuffle else { return Array(first..<count) + Array(0..<first) }
        var rest = Array(0..<count).filter { $0 != first }
        var rng = SeededGenerator(seed: seed)
        rest.shuffle(using: &rng)
        return [first] + rest
    }
}

/// A small repeatable random number generator (SplitMix64).
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
