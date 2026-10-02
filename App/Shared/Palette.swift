import SwiftUI

/// Dark surfaces, warm off-white text (never pure white), and the full Wong (2011)
/// color-vision-safe palette. Color always comes with a label, number, shape or position.
enum Palette {
    static let background = Color(hex: 0x13110F)
    static let surface = Color(hex: 0x1E1B18)
    static let surfaceRaised = Color(hex: 0x2A2622)
    static let hairline = Color(hex: 0x3A352F)

    static let text = Color(hex: 0xEDE6D6)
    static let textSecondary = Color(hex: 0xB9AF9F)
    static let textTertiary = Color(hex: 0x8A8175)

    static let orange = Color(hex: 0xE69F00)
    static let skyBlue = Color(hex: 0x56B4E9)
    static let green = Color(hex: 0x009E73)
    static let yellow = Color(hex: 0xF0E442)
    static let blue = Color(hex: 0x0072B2)
    static let vermillion = Color(hex: 0xD55E00)
    static let purple = Color(hex: 0xCC79A7)

    /// Series colors for charts, in a fixed order.
    static let series: [Color] = [skyBlue, orange, green, purple, yellow, vermillion, blue]
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
