import Foundation
import UIKit
import UniformTypeIdentifiers

enum FileStager {
  static func copy(_ url: URL, root: URL) throws -> URL {
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let parent = root.appendingPathComponent("Transfers/" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var coordinationError: NSError?
    var result: Result<URL, Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      source in
      result = Result {
        let name = source.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
          throw MobileError(message: "文件名称无效")
        }
        var count = 0
        func walk(_ src: URL, _ dst: URL, _ depth: Int) throws {
          count += 1
          guard depth < 64, count < 100000 else { throw MobileError(message: "目录过大或层级过深") }
          let values = try src.resourceValues(forKeys: [
            .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey,
          ])
          guard values.isSymbolicLink != true else {
            throw MobileError(message: "暂不导入符号链接；请先归档为 ZIP")
          }
          if values.isDirectory == true {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: false)
            for child in try FileManager.default.contentsOfDirectory(
              at: src, includingPropertiesForKeys: nil)
            { try walk(child, dst.appendingPathComponent(child.lastPathComponent), depth + 1) }
          } else {
            guard values.isRegularFile == true else { throw MobileError(message: "不支持此文件类型") }
            let free =
              (try FileManager.default.attributesOfFileSystem(forPath: parent.path)[.systemFreeSize]
              as? NSNumber)?.int64Value ?? 0
            guard free > Int64(values.fileSize ?? 0) + 64 * 1024 * 1024 else {
              throw MobileError(message: "暂存空间不足，请先释放空间")
            }
            try FileManager.default.copyItem(at: src, to: dst)
          }
        }
        let destination = parent.appendingPathComponent(name)
        try walk(source, destination, 0)
        return destination
      }
    }
    do {
      if let coordinationError { throw coordinationError }
      return try result?.get() ?? { throw MobileError(message: "文件提供器未返回内容") }()
    } catch {
      try? FileManager.default.removeItem(at: parent)
      throw error
    }
  }
  static func receive(_ provider: NSItemProvider, root: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { reply in
      provider.loadFileRepresentation(
        forTypeIdentifier: provider.hasItemConformingToTypeIdentifier(UTType.folder.identifier)
          ? UTType.folder.identifier : UTType.item.identifier
      ) { url, error in
        do {
          if let error { throw error }
          guard let url else { throw MobileError(message: "无法读取拖入的文件") }
          reply.resume(returning: try copy(url, root: root))
        } catch { reply.resume(throwing: error) }
      }
    }
  }
}
