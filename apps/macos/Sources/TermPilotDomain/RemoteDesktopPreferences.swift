import Foundation

public enum RemoteDesktopPreferences {
    public static let frameRateKey = "remoteDesktopFrameRate"
    public static let defaultFrameRate = 60
    public static let videoCodecKey = "remoteDesktopVideoCodec"
    public static func normalizedVideoCodec(_ value: String?) -> String { value == "h265" ? "h265" : "h264" }
    public static func videoCodec(defaults: UserDefaults = .standard) -> String { normalizedVideoCodec(defaults.string(forKey: videoCodecKey)) }

    public static func normalizedFrameRate(_ value: Int) -> Int {
        value == 30 ? 30 : defaultFrameRate
    }

    public static func frameRate(defaults: UserDefaults = .standard) -> Int {
        normalizedFrameRate(defaults.integer(forKey: frameRateKey))
    }
}
