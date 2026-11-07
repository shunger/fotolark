import FotolarkKit
import Foundation

/// The editing panel's sections and the edits each one controls, so a section can
/// show that it has changes and reset just those.
enum PanelSection: String, CaseIterable {
    case basic = "Basic fixes"
    case local = "Brush and gradient"
    case crop = "Crop and rotate"
    case effects = "Effects"
    case light = "Light"
    case color = "Color"
    case detail = "Detail"
    case curves = "Curves"
    case levels = "Levels"
    case colorRanges = "Color ranges"
    case lens = "Lens correction"
    case border = "Border"
    case vignette = "Vignette"

    /// Whole operations this section owns.
    var kinds: [EditOperation.Kind] {
        switch self {
        case .basic: [.magicFix, .autoContrast, .autoColor, .whiteBalance, .redEye, .retouch]
        case .local: [.local]
        case .crop: [.orient, .straighten, .crop, .resize, .text, .markup]
        case .effects: [.looks, .tiltShift, .backgroundBlur]
        case .curves: [.curves]
        case .levels: [.levels]
        case .colorRanges: [.colorRanges]
        case .lens: [.lens]
        case .border: [.border]
        case .light, .color, .detail, .vignette: []
        }
    }

    /// Sliders this section owns.
    var sliders: [WritableKeyPath<Adjustments, Double>] {
        switch self {
        case .basic: [\.fillLight]
        case .light: [\.exposure, \.brightness, \.contrast, \.highlights, \.shadows, \.whites, \.blacks]
        case .color: [\.temperature, \.tint, \.saturation, \.vibrance]
        case .detail: [\.sharpness, \.clarity, \.structure, \.noiseReduction, \.colorNoiseReduction]
        case .vignette: [\.vignette, \.vignetteSize]
        default: []
        }
    }

    func isEdited(_ recipe: EditRecipe) -> Bool {
        if kinds.contains(where: { recipe.operation($0) != nil }) { return true }
        let a = recipe.adjustments, plain = Adjustments()
        return sliders.contains { a[keyPath: $0] != plain[keyPath: $0] }
    }

    /// `recipe` with this section's edits taken out.
    func reset(_ recipe: EditRecipe) -> EditRecipe {
        var r = recipe
        for kind in kinds { r = r.removing(kind) }
        if !sliders.isEmpty {
            var a = r.adjustments
            let plain = Adjustments()
            for key in sliders { a[keyPath: key] = plain[keyPath: key] }
            r = r.settingAdjustments(a)
        }
        return r
    }
}

extension PhotoEditor {
    func isEdited(_ section: PanelSection) -> Bool { section.isEdited(recipe) }

    func reset(_ section: PanelSection) {
        if section == .crop { tool = .none }
        apply(section.reset(recipe), label: "Reset \(section.rawValue.lowercased())")
    }
}
