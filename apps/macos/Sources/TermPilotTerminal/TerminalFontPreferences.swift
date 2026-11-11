import AppKit
import CoreText
import Foundation

public enum TerminalFontPreferences {
    private static let cache = TerminalFontCatalogCache()

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
        let cacheKey = "\(name)|\(size)"
        if let font = cache.font(for: cacheKey) { return font }
        let family = name.isEmpty ? automaticFontFamily() : name
        if let family,
           let font = NSFontManager.shared.font(
               withFamily: family,
               traits: [.fixedPitchFontMask],
               weight: 5,
               size: size
           )
        {
            cache.store(font: font, for: cacheKey)
            return font
        }
        if let family,
           let font = NSFont(name: family, size: size)
        {
            cache.store(font: font, for: cacheKey)
            return font
        }
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        cache.store(font: font, for: cacheKey)
        return font
    }

    public static func availableFontFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter(isTerminalCandidate)
            .sorted { lhs, rhs in
                lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    public static func availableFontFamiliesAsync() async -> [String] {
        if let families = cache.terminalFamilies { return families }
        let revision = cache.revision
        let result = await Task.detached(priority: .userInitiated) {
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
        cache.store(families: result, revision: revision)
        return result
    }

    public static func automaticFontFamily() -> String? {
        let available = cache.allFamilies
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


private final class TerminalFontCatalogCache: @unchecked Sendable {
    private let lock = NSLock()
    private var fonts: [String: NSFont] = [:]
    private var families: [String]?
    private var all: Set<String>?
    private var version = 0
    private var observer: (any NSObjectProtocol)?
    init() {
        observer = NotificationCenter.default.addObserver(forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String), object: nil, queue: nil) { [weak self] _ in
            self?.invalidate()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func invalidate() { lock.withLock { fonts.removeAll(); families = nil; all = nil; version += 1 } }
    var revision: Int { lock.withLock { version } }
    var terminalFamilies: [String]? { lock.withLock { families } }
    var allFamilies: Set<String> {
        lock.withLock {
            if let all { return all }
            let result = Set(CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
            all = result
            return result
        }
    }
    func store(families: [String], revision: Int) { lock.withLock { if version == revision { self.families = families } } }
    func font(for key: String) -> NSFont? { lock.withLock { fonts[key] } }
    func store(font: NSFont, for key: String) { lock.withLock { fonts[key] = font } }
}
