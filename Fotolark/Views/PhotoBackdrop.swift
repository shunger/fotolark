import SwiftUI

/// What sits behind photos while editing, comparing and in the filmstrip. Dark by
/// default: colors and brightness are judged best against a dark, neutral surround.
enum PhotoBackground: String, CaseIterable, Identifiable {
    case dark, gray, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: "Dark"
        case .gray: "Neutral Gray"
        case .system: "Match the System"
        }
    }

    static let key = "photoBackground"

    /// The setting, picking up the older "neutral gray" switch the first time.
    static var current: PhotoBackground {
        if let raw = UserDefaults.standard.string(forKey: key), let v = PhotoBackground(rawValue: raw) { return v }
        return UserDefaults.standard.bool(forKey: "neutralGrayBackground") ? .gray : .dark
    }
}

/// The backdrop itself.
struct PhotoBackdrop: View {
    @AppStorage(PhotoBackground.key) private var choice = PhotoBackground.current

    var body: some View {
        switch choice {
        case .dark: Color(white: 0.11)
        case .gray: Color(white: 0.45)
        case .system: Color(nsColor: .underPageBackgroundColor)
        }
    }

    /// Light text and controls belong on the dark and gray backdrops.
    static var prefersDarkControls: Bool { PhotoBackground.current != .system }
}
