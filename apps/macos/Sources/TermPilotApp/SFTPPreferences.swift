import Foundation
import TermPilotRemote

enum SFTPPreferences {
    static let showsHiddenFilesKey = "sftpShowsHiddenFiles"
    static let fileTransferConcurrencyKey = "sftpFileTransferConcurrency"
    static let chunkConcurrencyKey = "sftpChunkConcurrency"
    static let chunkSizeBytesKey = "sftpChunkSizeBytes"
    static let transferConnectionIdleSecondsKey =
        "sftpTransferConnectionIdleSeconds"

    static let defaultShowsHiddenFiles = true
    static let defaultFileTransferConcurrency = 2
    static let defaultChunkConcurrency = 32
    static let defaultChunkSizeBytes = 256 * 1_024
    static let defaultTransferConnectionIdleSeconds = 5 * 60

    static let fileTransferConcurrencyRange = 1 ... 16
    static let chunkConcurrencyRange = 1 ... 32
    static let chunkSizePresets = [
        256 * 1_024,
        512 * 1_024,
        1 * 1_024 * 1_024,
        5 * 1_024 * 1_024,
        10 * 1_024 * 1_024,
    ]
    static let transferConnectionIdleSecondPresets = [
        60,
        5 * 60,
        15 * 60,
        30 * 60,
        0,
    ]

    static var showsHiddenFiles: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: showsHiddenFilesKey) != nil else {
            return defaultShowsHiddenFiles
        }
        return defaults.bool(forKey: showsHiddenFilesKey)
    }

    static var transferOptions: SFTPTransferOptions {
        let defaults = UserDefaults.standard
        return SFTPTransferOptions(
            fileConcurrency: clampedFileTransferConcurrency(
                defaults.object(forKey: fileTransferConcurrencyKey) as? Int
                    ?? defaultFileTransferConcurrency
            ),
            chunkConcurrency: clampedChunkConcurrency(
                defaults.object(forKey: chunkConcurrencyKey) as? Int
                    ?? defaultChunkConcurrency
            ),
            chunkSizeBytes: normalizedChunkSizeBytes(
                defaults.object(forKey: chunkSizeBytesKey) as? Int
                    ?? defaultChunkSizeBytes
            )
        )
    }

    static var transferConnectionIdleSeconds: Int {
        normalizedTransferConnectionIdleSeconds(
            UserDefaults.standard.object(
                forKey: transferConnectionIdleSecondsKey
            ) as? Int ?? defaultTransferConnectionIdleSeconds
        )
    }

    static func clampedFileTransferConcurrency(_ value: Int) -> Int {
        min(
            max(value, fileTransferConcurrencyRange.lowerBound),
            fileTransferConcurrencyRange.upperBound
        )
    }

    static func clampedChunkConcurrency(_ value: Int) -> Int {
        min(
            max(value, chunkConcurrencyRange.lowerBound),
            chunkConcurrencyRange.upperBound
        )
    }

    static func normalizedChunkSizeBytes(_ value: Int) -> Int {
        chunkSizePresets.contains(value) ? value : defaultChunkSizeBytes
    }

    static func normalizedTransferConnectionIdleSeconds(
        _ value: Int
    ) -> Int {
        transferConnectionIdleSecondPresets.contains(value)
            ? value
            : defaultTransferConnectionIdleSeconds
    }

    static func chunkSizeTitle(_ bytes: Int) -> String {
        switch bytes {
        case 256 * 1_024:
            "256 KB"
        case 512 * 1_024:
            "512 KB"
        case 1 * 1_024 * 1_024:
            "1 MB"
        case 5 * 1_024 * 1_024:
            "5 MB"
        case 10 * 1_024 * 1_024:
            "10 MB"
        default:
            "\(bytes) B"
        }
    }
}
