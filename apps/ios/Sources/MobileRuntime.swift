import Foundation
import Security
import TermPilotMobile

typealias JSON = [String: Any]
extension Dictionary where Key == String, Value == Any {
  func text(_ key: String, _ fallback: String = "") -> String { self[key] as? String ?? fallback }
  func number(_ key: String, _ fallback: Int = 0) -> Int {
    (self[key] as? NSNumber)?.intValue ?? fallback
  }
  func object(_ key: String) -> JSON { self[key] as? JSON ?? [:] }
  func array(_ key: String) -> [JSON] { self[key] as? [JSON] ?? [] }
}
struct MobileError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
struct MobilePacket {
  let header: JSON
  let data: Data
  static func decode(_ bytes: Data) throws -> MobilePacket {
    guard bytes.count >= 4 else { throw MobileError(message: "Invalid mobile event packet") }
    let n=bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    // Command output/file text is carried in control JSON, not a small frame header.
    guard n >= 2, n <= 128 * 1024 * 1024, n <= bytes.count - 4,
      let header=try JSONSerialization.jsonObject(with:bytes.subdata(in:4..<(4+n))) as? JSON
    else { throw MobileError(message: "Invalid mobile event length") }
    return MobilePacket(header:header,data:bytes.subdata(in:(4+n)..<bytes.count))
  }
}

/// All vault calls run off the main thread. Polling never borrows a Rust buffer after free.
final class MobileRuntime: @unchecked Sendable {
  let handle: UInt64
  let directory: URL
  private let queue = DispatchQueue(label: "TermPilot.requests")
  private let syncQueue = DispatchQueue(label: "TermPilot.sync", qos: .utility)
  private let syncStatusQueue = DispatchQueue(label: "TermPilot.sync.status", qos: .utility)
  private let polling = DispatchQueue(label: "TermPilot.events", qos: .userInitiated)
  private let lock = NSLock()
  private var stopped = false
  init(directory: URL? = nil, testKey: Data? = nil) throws {
    self.directory =
      directory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TermPilot", isDirectory: true)
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    var key =
      try testKey
      ?? Self.key(
        existingVault: FileManager.default.fileExists(
          atPath: self.directory.appendingPathComponent("vault.sqlite").path))
    defer { key.resetBytes(in: 0..<key.count) }
    handle = self.directory.path.withCString { path in
      key.withUnsafeBytes { raw in
        tp_mobile_create(path, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
      }
    }
    guard handle != 0 else { throw MobileError(message: "无法打开 TermPilot 数据库，请检查设备钥匙串与备份。") }
  }
  private static func key(existingVault: Bool) throws -> Data {
    let query: JSON = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "TermPilot",
      kSecAttrAccount as String: "vault-key",
    ]
    var result: CFTypeRef?
    var read = query
    read[kSecReturnData as String] = true
    let status = SecItemCopyMatching(read as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
    guard status == errSecItemNotFound else {
      throw MobileError(message: "钥匙串暂不可用（\(status)），请解锁设备后重试。")
    }
    guard !existingVault else { throw MobileError(message: "现有数据库的钥匙串密钥缺失，请从加密备份恢复。") }
    var data = Data(count: 32)
    let random = data.withUnsafeMutableBytes {
      SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
    }
    guard random == errSecSuccess else { throw MobileError(message: "无法生成加密密钥。") }
    var add = query
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
      throw MobileError(message: "无法保存加密密钥。")
    }
    return data
  }
  func call(_ request: JSON) async throws -> JSON {
    try await withCheckedThrowingContinuation { continuation in
      let method = request.text("method")
      // A long migration must not queue its own progress reads behind itself.
      let target = ["sync.status", "sync.describe", "sync.progress"].contains(method) ? syncStatusQueue
        : method.hasPrefix("sync.") && method != "sync.preferences" ? syncQueue : queue
      target.async { [self] in
        do {
          let data = try JSONSerialization.data(withJSONObject: request)
          let pointer = data.withUnsafeBytes {
            tp_mobile_call(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
          }
          guard let pointer else { throw MobileError(message: "Rust 调用失败") }
          defer { tp_mobile_free_string(pointer) }
          let response =
            try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? JSON
            ?? [:]
          guard response["ok"] as? Bool == true else {
            throw MobileError(message: response.object("error").text("message", "操作失败"))
          }
          continuation.resume(returning: response.object("value"))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  func start(_ deliver: @escaping @Sendable (MobilePacket) -> Void) {
    polling.async { [self] in
      while true {
        lock.lock()
        let stop = stopped
        lock.unlock()
        if stop { break }
        var length = 0
        guard let bytes = tp_mobile_poll(handle, 100, &length) else { continue }
        let data = Data(bytes: bytes, count: length)
        tp_mobile_free_buffer(bytes, length)
        guard let packet = try? MobilePacket.decode(data) else { continue }
        deliver(packet)
      }
      tp_mobile_destroy(handle)
    }
  }
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
    tp_mobile_destroy(handle)
  }
  deinit { stop() }
}
