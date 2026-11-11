import SwiftUI

enum SSHLatency {
  static func parse(_ message: String) -> Int? {
    guard let value = Double(message.trimmingCharacters(in: .whitespacesAndNewlines)),
          value.isFinite, value >= 0, value <= Double(Int32.max) else { return nil }
    return Int(value.rounded())
  }

  static func color(_ milliseconds: Int) -> Color {
    milliseconds <= 150 ? .green : milliseconds <= 400 ? .orange : .red
  }
}
