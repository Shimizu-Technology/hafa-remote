import SwiftUI
import UIKit

/// Shared adaptive colors for Hafa Remote's local-first interface.
enum HafaTheme {
    static let canvas = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.035, green: 0.067, blue: 0.102, alpha: 1)
                : UIColor(red: 0.957, green: 0.976, blue: 0.973, alpha: 1)
        }
    )
    static let surface = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.071, green: 0.118, blue: 0.157, alpha: 1)
                : UIColor.white
        }
    )
    static let accent = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 0.247, green: 0.831, blue: 0.733, alpha: 1)
            }
            return traits.accessibilityContrast == .high
                ? UIColor(red: 0.015, green: 0.310, blue: 0.278, alpha: 1)
                : UIColor(red: 0.027, green: 0.455, blue: 0.408, alpha: 1)
        }
    )
    static let primaryText = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let controlBorder = Color(uiColor: .separator)
}
