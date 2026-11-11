import Foundation

public enum HighPerformanceResolution: String, CaseIterable, Sendable {
    case hd = "1280x720"
    case fullHD = "1920x1080"
    case qhd = "2560x1440"
    case uhd = "3840x2160"

    public var width: Int {
        switch self { case .hd: 1280; case .fullHD: 1920; case .qhd: 2560; case .uhd: 3840 }
    }
    public var height: Int {
        switch self { case .hd: 720; case .fullHD: 1080; case .qhd: 1440; case .uhd: 2160 }
    }
    public var title: String {
        "\(width) × \(height)"
    }
}
