import SwiftUI

// MARK: - Hex color

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Mix towards another color. fraction 0 = self, 1 = other.
    func mixed(with other: Color, fraction: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let f = CGFloat(fraction)
        return Color(.sRGB,
                     red: Double(r1 + (r2 - r1) * f),
                     green: Double(g1 + (g2 - g1) * f),
                     blue: Double(b1 + (b2 - b1) * f),
                     opacity: Double(a1 + (a2 - a1) * f))
    }
}

// MARK: - Theme model (mirrors pi-desktop's seed -> token system)

struct ThemeSeed: Codable, Equatable {
    var app: String
    var surface: String
    var text: String
    var accent: String
    var success: String
    var warning: String
    var error: String
}

struct PiTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let seed: ThemeSeed

    var appBG: Color { Color(hex: seed.app) }
    var surface: Color { Color(hex: seed.surface) }
    var surface2: Color { surface.mixed(with: Color(hex: seed.text), fraction: isDark ? 0.06 : 0.05) }
    var surface3: Color { surface.mixed(with: Color(hex: seed.text), fraction: isDark ? 0.12 : 0.10) }

    var textPrimary: Color { Color(hex: seed.text) }
    var textSecondary: Color { Color(hex: seed.text).opacity(0.72) }
    var textMuted: Color { Color(hex: seed.text).opacity(0.52) }
    var textFaint: Color { Color(hex: seed.text).opacity(0.36) }

    var accent: Color { Color(hex: seed.accent) }
    var success: Color { Color(hex: seed.success) }
    var warning: Color { Color(hex: seed.warning) }
    var error: Color { Color(hex: seed.error) }

    var border: Color { Color(hex: seed.text).opacity(isDark ? 0.10 : 0.14) }
    var borderStrong: Color { Color(hex: seed.text).opacity(isDark ? 0.18 : 0.22) }

    var codeBG: Color { appBG.mixed(with: Color(hex: seed.text), fraction: isDark ? 0.05 : 0.04) }

    static let builtIns: [PiTheme] = [
        PiTheme(id: "dark", name: "Dark", isDark: true, seed: ThemeSeed(
            app: "#0a0a0a", surface: "#171717", text: "#f5f5f5",
            accent: "#2563eb", success: "#34d399", warning: "#facc15", error: "#f87171")),
        PiTheme(id: "light", name: "Light", isDark: false, seed: ThemeSeed(
            app: "#fafafa", surface: "#ffffff", text: "#1a1a1a",
            accent: "#2563eb", success: "#059669", warning: "#ca8a04", error: "#dc2626")),
        PiTheme(id: "nord", name: "Nord", isDark: true, seed: ThemeSeed(
            app: "#2e3440", surface: "#3b4252", text: "#eceff4",
            accent: "#88c0d0", success: "#a3be8c", warning: "#ebcb8b", error: "#bf616a")),
        PiTheme(id: "gruvbox", name: "Gruvbox", isDark: true, seed: ThemeSeed(
            app: "#282828", surface: "#3c3836", text: "#ebdbb2",
            accent: "#fe8019", success: "#b8bb26", warning: "#fabd2f", error: "#fb4934")),
        PiTheme(id: "breeze-light", name: "Breeze Light", isDark: false, seed: ThemeSeed(
            app: "#eef2f7", surface: "#ffffff", text: "#1f2937",
            accent: "#0ea5e9", success: "#10b981", warning: "#f59e0b", error: "#ef4444")),
    ]

    static let `default` = builtIns[0]

    static func theme(withID id: String) -> PiTheme {
        builtIns.first { $0.id == id } ?? .default
    }
}
