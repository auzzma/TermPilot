import Foundation

enum AppResourceLocator {
    private static let resourceBundleName = "TermPilot_TermPilotApp.bundle"

    static func url(
        forResource name: String,
        withExtension ext: String,
        subdirectory: String? = nil
    ) -> URL? {
        for bundle in resourceBundles {
            if let url = bundle.url(
                forResource: name,
                withExtension: ext,
                subdirectory: subdirectory
            ) ?? bundle.url(
                forResource: name,
                withExtension: ext
            ) {
                return url
            }
        }

        for directory in sourceResourceDirectories {
            let candidate = subdirectory.map {
                directory.appendingPathComponent($0)
            } ?? directory
            let url = candidate
                .appendingPathComponent(name)
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }

            let flatURL = directory
                .appendingPathComponent(name)
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: flatURL.path) {
                return flatURL
            }
        }

        return nil
    }

    static func localizedBundle(for language: String) -> Bundle {
        let candidates = [language, language.lowercased()]
        for bundle in resourceBundles {
            for candidate in candidates {
                if let path = bundle.path(forResource: candidate, ofType: "lproj"),
                   let localizedBundle = Bundle(path: path)
                {
                    return localizedBundle
                }
            }
        }

        for directory in sourceResourceDirectories {
            for candidate in candidates {
                let url = directory.appendingPathComponent("\(candidate).lproj")
                if let localizedBundle = Bundle(url: url) {
                    return localizedBundle
                }
            }
        }

        return .main
    }

    private static var resourceBundles: [Bundle] {
        resourceBundleURLs.compactMap(Bundle.init(url:))
    }

    private static var resourceBundleURLs: [URL] {
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent(resourceBundleName))
        }
        urls.append(Bundle.main.bundleURL.appendingPathComponent(resourceBundleName))
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            urls.append(executableDirectory.appendingPathComponent(resourceBundleName))
        }
        return uniqueExistingURLs(urls)
    }

    private static var sourceResourceDirectories: [URL] {
        #if DEBUG
        let sourceFile = URL(fileURLWithPath: #filePath)
        let sourceDirectory = sourceFile.deletingLastPathComponent()
        return uniqueExistingURLs([
            sourceDirectory.appendingPathComponent("Resources"),
        ])
        #else
        return []
        #endif
    }

    private static func uniqueExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path),
                  FileManager.default.fileExists(atPath: path)
            else {
                return false
            }
            seen.insert(path)
            return true
        }
    }
}
