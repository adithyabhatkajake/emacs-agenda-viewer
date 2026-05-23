import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static func dynamic(light: Color, dark: Color) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #else
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}

enum Theme {
    // MARK: - Surfaces
    static let background = Color.dynamic(
        light: Color.white,
        dark:  Color(red: 45/255,  green: 45/255,  blue: 47/255)
    )
    static let surface = Color.dynamic(
        light: Color(red: 240/255, green: 240/255, blue: 242/255),
        dark:  Color(red: 50/255,  green: 50/255,  blue: 52/255)
    )
    static let surfaceElevated = Color.dynamic(
        light: Color(red: 232/255, green: 232/255, blue: 237/255),
        dark:  Color(red: 58/255,  green: 58/255,  blue: 60/255)
    )
    static let border = Color.dynamic(
        light: Color(red: 209/255, green: 209/255, blue: 214/255),
        dark:  Color(red: 58/255,  green: 58/255,  blue: 60/255)
    )
    static let borderSubtle = Color.dynamic(
        light: Color(red: 229/255, green: 229/255, blue: 234/255),
        dark:  Color(red: 56/255,  green: 56/255,  blue: 58/255)
    )

    // MARK: - Accents (theme-aware to match the design tokens)
    static let accent = Color.dynamic(
        light: Color(red: 52/255,  green: 120/255, blue: 246/255),
        dark:  Color(red: 95/255,  green: 160/255, blue: 244/255)
    )
    static let accentTeal = Color.dynamic(
        light: Color(red: 0/255,   green: 164/255, blue: 199/255),
        dark:  Color(red: 100/255, green: 210/255, blue: 255/255)
    )

    // MARK: - Text
    static let textPrimary = Color.dynamic(
        light: Color(red: 29/255,  green: 29/255,  blue: 31/255),
        dark:  Color(red: 245/255, green: 245/255, blue: 247/255)
    )
    static let textSecondary = Color.dynamic(
        light: Color(red: 110/255, green: 110/255, blue: 115/255),
        dark:  Color(red: 152/255, green: 152/255, blue: 157/255)
    )
    static let textTertiary = Color.dynamic(
        light: Color(red: 174/255, green: 174/255, blue: 178/255),
        dark:  Color(red: 99/255,  green: 99/255,  blue: 102/255)
    )

    // MARK: - Status (theme-aware per design tokens)
    static let doneGreen = Color.dynamic(
        light: Color(red: 52/255, green: 199/255, blue: 89/255),
        dark:  Color(red: 48/255, green: 209/255, blue: 88/255)
    )
    static let priorityA = Color.dynamic(
        light: Color(red: 255/255, green: 59/255, blue: 48/255),
        dark:  Color(red: 255/255, green: 69/255, blue: 58/255)
    )
    static let priorityB = Color.dynamic(
        light: Color(red: 255/255, green: 149/255, blue: 0/255),
        dark:  Color(red: 255/255, green: 159/255, blue: 10/255)
    )
    static let priorityC = Color.dynamic(
        light: Color(red: 52/255, green: 120/255, blue: 246/255),
        dark:  Color(red: 95/255, green: 160/255, blue: 244/255)
    )
    static let priorityD = Color.dynamic(
        light: Color(red: 142/255, green: 142/255, blue: 147/255),
        dark:  Color(red: 99/255,  green: 99/255,  blue: 102/255)
    )

    static func priorityColor(_ priority: String?) -> Color {
        switch priority?.uppercased() {
        case "A": return priorityA
        case "B": return priorityB
        case "C": return priorityC
        case "D": return priorityD
        default: return textTertiary
        }
    }
}
