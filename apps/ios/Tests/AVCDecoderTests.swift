import XCTest
@_silgen_name("tp_mobile_avc_probe") private func avcProbe(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> Int32
final class AVCDecoderTests: XCTestCase {
  func testNativeH264Frames() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264", withExtension: "fixture"))
    let data = try Data(contentsOf: url)
    let status = data.withUnsafeBytes { avcProbe($0.baseAddress!.assumingMemoryBound(to: UInt8.self), $0.count) }
    XCTAssertEqual(status, 0)
  }
}
