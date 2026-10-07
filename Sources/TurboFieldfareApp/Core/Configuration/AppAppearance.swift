/// Light or dark for the app's windows, independent of the system setting.
public enum AppAppearance: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Follow System Settings ▸ Appearance.
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
