import AppKit
import CoreText
import Foundation

public enum TerminalFontPreferences {
    public static let fontNameKey = "terminalFontName"
    public static let fontSizeKey = "terminalFontSize"
    public static let automaticFontName = ""
    public static let defaultFontSize = 13.0
    public static let minimumFontSize = 8.0
    public static let maximumFontSize = 36.0

    private static let preferredFontFamilies = [
        "MesloLGS NF",
        "MesloLGS Nerd Font Mono",
        "JetBrainsMono Nerd Font",
        "JetBrainsMono Nerd Font Mono",
        "Hack Nerd Font",
        "Hack Nerd Font Mono",
        "FiraCode Nerd Font",
        "FiraCode Nerd Font Mono",
        "CaskaydiaCove Nerd Font",
        "CaskaydiaCove Nerd Font Mono",
        "Symbols Nerd Font Mono",
        "Menlo",
        "Monaco",
    ]

    public static func preferredFont(
        defaults: UserDefaults = .standard,
        defaultSize: Double = defaultFontSize
    ) -> NSFont {
        let storedSize = defaults.double(forKey: fontSizeKey)
        let size = clampedFontSize(storedSize > 0 ? storedSize : defaultSize)
        let storedName = defaults.string(forKey: fontNameKey) ?? automaticFontName
        return font(named: storedName, size: size)
    }

    public static func font(named name: String, size: Double) -> NSFont {
        let family = name.isEmpty ? automaticFontFamily() : name
        if let family,
           let font = NSFontManager.shared.font(
               withFamily: family,
               traits: [.fixedPitchFontMask],
               weight: 5,
               size: size
           )
        {
            return font
        }
        if let family,
           let font = NSFont(name: family, size: size)
        {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public static func availableFontFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter(isTerminalCandidate)
            .sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    public static func availableFontFamiliesAsync() async -> [String] {
        await Task.detached(priority: .userInitiated) {
            let families =
                CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
            return families
                .filter { family in
                    if matchesTerminalFamilyName(family) {
                        return true
                    }
                    let font = CTFontCreateWithName(
                        family as CFString,
                        CGFloat(defaultFontSize),
                        nil
                    )
                    return CTFontGetSymbolicTraits(font)
                        .contains(.traitMonoSpace)
                }
                .sorted { lhs, rhs in
                    lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
        }.value
    }

    public static func automaticFontFamily() -> String? {
        let available = Set(NSFontManager.shared.availableFontFamilies)
        return preferredFontFamilies.first { available.contains($0) }
    }

    public static func clampedFontSize(_ value: Double) -> Double {
        min(max(value, minimumFontSize), maximumFontSize)
    }

    private static func isTerminalCandidate(_ family: String) -> Bool {
        if matchesTerminalFamilyName(family) {
            return true
        }
        guard let font = NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: 5,
            size: defaultFontSize
        ) else {
            return false
        }
        return NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask)
    }

    private static func matchesTerminalFamilyName(_ family: String) -> Bool {
        let normalized = family.lowercased()
        if normalized.contains("nerd")
            || normalized.contains("powerline")
            || normalized.contains("mono")
            || normalized.contains("code")
            || normalized.contains("menlo")
            || normalized.contains("monaco")
        {
            return true
        }
        return false
    }
}
