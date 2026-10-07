import SwiftUI
import UIKit

/// Semantic colors for the Warm teal system, resolved for appearance and contrast.
enum HafaTheme {
    static let canvas = adaptive(light: 0xF7F5EF, dark: 0x111B1C)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x1C292B)
    static let primaryText = adaptive(light: 0x192927, dark: 0xEDF3EF)
    static let secondaryText = adaptive(
        light: 0x59665E, dark: 0xAFBFBA,
        highContrastLight: 0x35423A, highContrastDark: 0xD2DED8)
    static let accent = adaptive(
        light: 0x12685D, dark: 0x78D5BF,
        highContrastLight: 0x0B5148, highContrastDark: 0x9AE8D5)
    static let onAccent = adaptive(light: 0xFFFFFF, dark: 0x112A23)
    static let controlBorder = adaptive(
        light: 0x7B8982, dark: 0x748D85,
        highContrastLight: 0x35483F, highContrastDark: 0xB9CEC5)
    static let warning = adaptive(light: 0x835018, dark: 0xF0BD7C)

    private static func adaptive(
        light: UInt32, dark: UInt32,
        highContrastLight: UInt32? = nil, highContrastDark: UInt32? = nil
    ) -> Color {
        Color(
            uiColor: UIColor { traits in
                let isDark = traits.userInterfaceStyle == .dark
                let isHighContrast = traits.accessibilityContrast == .high
                let hex =
                    isDark
                    ? (isHighContrast ? highContrastDark ?? dark : dark)
                    : (isHighContrast ? highContrastLight ?? light : light)
                return UIColor(
                    red: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255,
                    alpha: 1
                )
            })
    }
}
