import Foundation

public struct RemoteSystemInfo: Codable, Equatable, Sendable {
    public var platform: String
    public var username: String
    public var isWindows: Bool { platform == "windows" }
}

/// Shared Rust monitor response, in bytes and percentages (0...100).
public struct RemoteWindowsOverview: Decodable, Sendable {
    public struct Disk: Decodable, Sendable {
        public var mount: String
        public var used: Double
        public var total: Double
        public var percent: Double
    }
    public struct NetworkInterface: Decodable, Sendable {
        public var name: String
        public var rxPerSecond: Double
        public var txPerSecond: Double
    }
    public struct TopProcess: Decodable, Sendable {
        public var pid: Int
        public var memoryPercent: Double
        public var command: String
    }
    public var os: String
    public var kernel: String
    public var uptimeSeconds: Double
    public var cpuReady: Bool
    public var cpuUsage: Double
    public var cpuUserUsage: Double
    public var cpuSystemUsage: Double
    public var cpuCoreCount: Int
    public var memoryTotal: Double
    public var memoryUsed: Double
    public var disks: [Disk]
    public var networkRxPerSecond: Double
    public var networkTxPerSecond: Double
    public var networkInterfaces: [NetworkInterface]
    public var swap: String
    public var topMemoryProcesses: [TopProcess]
}

public struct RemoteWindowsProcesses: Decodable, Sendable {
    public struct Row: Decodable, Sendable {
        public var pid: Int
        public var ppid: Int
        public var user: String
        public var stat: String
        public var cpuPercent: Double
        public var cpuReady: Bool
        public var memPercent: Double
        public var rssKB: Int
        public var vszKB: Int
        public var elapsed: String
        public var command: String
    }
    public var processes: [Row]
}
