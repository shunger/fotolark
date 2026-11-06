import Foundation

/// A photo's edits: an ordered list of operations replayed on top of the untouched original.
///
/// The editing helpers keep at most one operation of each kind, in a fixed order
/// (tone and color, then orientation, straighten, crop and resize). That keeps the crop
/// rectangle in a predictable frame: turning or flipping the photo transforms an existing
/// crop instead of stacking a second one.
public struct EditRecipe: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var operations: [EditOperation]

    public init(operations: [EditOperation] = []) {
        self.version = Self.currentVersion
        self.operations = operations
    }

    public var isEmpty: Bool { operations.isEmpty }

    public func operation(_ kind: EditOperation.Kind) -> EditOperation? {
        operations.first { $0.kind == kind }
    }

    // MARK: Typed accessors

    public var adjustments: Adjustments {
        if case .adjust(let a) = operation(.adjust) { return a }
        return Adjustments()
    }

    public var orientation: Orientation {
        if case .orient(let o) = operation(.orient) { return o }
        return .identity
    }

    public var straightenDegrees: Double {
        if case .straighten(let d) = operation(.straighten) { return d }
        return 0
    }

    public var cropRect: CropRect? {
        if case .crop(let r) = operation(.crop) { return r }
        return nil
    }

    public var lens: LensCorrection {
        if case .lens(let l) = operation(.lens) { return l }
        return LensCorrection()
    }

    public var localAdjustments: [LocalAdjustment] {
        if case .local(let l) = operation(.local) { return l }
        return []
    }

    public var tiltShift: TiltShift? {
        if case .tiltShift(let t) = operation(.tiltShift) { return t }
        return nil
    }

    public var backgroundBlur: BackgroundBlur? {
        if case .backgroundBlur(let b) = operation(.backgroundBlur) { return b }
        return nil
    }

    public var resize: ResizeSpec? {
        if case .resize(let r) = operation(.resize) { return r }
        return nil
    }

    // MARK: Editing

    /// Returns a recipe with `operation` replacing any operation of the same kind, or
    /// inserted at its canonical position. Identity operations are removed instead.
    public func setting(_ operation: EditOperation) -> EditRecipe {
        if operation.isIdentity { return removing(operation.kind) }
        var copy = self
        if let i = copy.operations.firstIndex(where: { $0.kind == operation.kind }) {
            copy.operations[i] = operation
        } else {
            let i = copy.operations.firstIndex { $0.kind > operation.kind } ?? copy.operations.endIndex
            copy.operations.insert(operation, at: i)
        }
        return copy
    }

    public func removing(_ kind: EditOperation.Kind) -> EditRecipe {
        var copy = self
        copy.operations.removeAll { $0.kind == kind }
        return copy
    }

    public func settingAdjustments(_ adjustments: Adjustments) -> EditRecipe {
        setting(.adjust(adjustments))
    }

    /// Turns the photo a quarter turn. An existing crop turns with it; a resize keeps its
    /// pixel count but swaps width and height.
    public func rotated(clockwise: Bool) -> EditRecipe {
        var r = setting(.orient(orientation.rotated(clockwise: clockwise)))
        if let crop = cropRect {
            r = r.setting(.crop(clockwise ? crop.rotatedClockwise() : crop.rotatedCounterclockwise()))
        }
        if let size = resize {
            r = r.setting(.resize(ResizeSpec(width: size.height, height: size.width, dpi: size.dpi)))
        }
        // A straighten angle stays the same: it is applied after the turn.
        return r
    }

    public func flipped(horizontally: Bool) -> EditRecipe {
        let o = horizontally ? orientation.flippedHorizontally() : orientation.flippedVertically()
        var r = setting(.orient(o))
        if let crop = cropRect {
            r = r.setting(.crop(horizontally ? crop.flippedHorizontally() : crop.flippedVertically()))
        }
        // Mirroring the picture mirrors the tilt as well.
        if straightenDegrees != 0 {
            r = r.setting(.straighten(degrees: -straightenDegrees))
        }
        return r
    }

    /// The recipe up to (not including) the first operation of `kind` or any later kind.
    public func prefix(before kind: EditOperation.Kind) -> EditRecipe {
        EditRecipe(operations: operations.filter { $0.kind < kind })
    }

    /// The recipe without its final resize, as shown on screen.
    public var withoutResize: EditRecipe { removing(.resize) }
}
