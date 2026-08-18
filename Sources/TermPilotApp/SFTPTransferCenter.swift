import Foundation
import SwiftUI

enum FileTransferKind: String, Sendable {
    case upload
    case download
}

enum FileTransferStatus: Equatable, Sendable {
    case queued
    case running
    case paused
    case attention(String)
    case succeeded
    case failed(String)
    case cancelled
}

enum FileTransferBucket: String, CaseIterable, Identifiable {
    case all
    case active
    case queued
    case paused
    case attention
    case completed

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all:
            "All"
        case .active:
            "Active"
        case .queued:
            "Queued"
        case .paused:
            "Paused"
        case .attention:
            "Attention"
        case .completed:
            "Completed"
        }
    }
}

struct FileTransferRecord: Identifiable, Equatable, Sendable {
    var id: UUID
    var kind: FileTransferKind
    var name: String
    var sourcePath: String
    var destinationPath: String
    var bytesTransferred: UInt64
    var totalBytes: UInt64?
    var bytesPerSecond: Double
    var supportsPause: Bool
    var status: FileTransferStatus
    var startedAt: Date
    var finishedAt: Date?
    var sampledBytes: UInt64
    var sampledAt: Date

    init(
        id: UUID = UUID(),
        kind: FileTransferKind,
        name: String,
        sourcePath: String,
        destinationPath: String,
        bytesTransferred: UInt64 = 0,
        totalBytes: UInt64? = nil,
        bytesPerSecond: Double = 0,
        supportsPause: Bool = true,
        status: FileTransferStatus = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        sampledBytes: UInt64? = nil,
        sampledAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.supportsPause = supportsPause
        self.status = status
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.sampledBytes = sampledBytes ?? bytesTransferred
        self.sampledAt = sampledAt ?? startedAt
    }

    var progressFraction: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return nil
        }
        return min(Double(bytesTransferred) / Double(totalBytes), 1)
    }

    var canRetry: Bool {
        switch status {
        case .failed, .cancelled, .paused, .attention:
            true
        case .queued, .running, .succeeded:
            false
        }
    }

    var isUnfinished: Bool {
        switch status {
        case .queued, .running, .paused, .attention:
            true
        case .succeeded, .failed, .cancelled:
            false
        }
    }

    func belongs(to bucket: FileTransferBucket) -> Bool {
        switch bucket {
        case .all:
            true
        case .active:
            status == .running
        case .queued:
            status == .queued
        case .paused:
            status == .paused
        case .attention:
            if case .attention = status {
                true
            } else {
                false
            }
        case .completed:
            switch status {
            case .succeeded, .failed, .cancelled:
                true
            case .queued, .running, .paused, .attention:
                false
            }
        }
    }
}
