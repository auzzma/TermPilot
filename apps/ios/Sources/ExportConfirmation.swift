import Darwin
import SwiftUI

enum AppleFileMetadata {
  static func needsConfirmation(_ urls: [URL]) -> Bool {
    var count = 0
    func inspect(_ url: URL) -> Bool {
      count += 1
      guard count <= 100000 else { return true }
      for name in ["com.apple.ResourceFork", "com.apple.FinderInfo"] {
        if getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) > 0 { return true }
      }
      guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
        values.isSymbolicLink != true
      else { return true }
      if values.isDirectory == true {
        guard
          let children = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil)
        else { return true }
        for child in children { if inspect(child) { return true } }
      }
      return false
    }
    return urls.contains { inspect($0) }
  }
}

/// The downloaded original stays private; exporting through a file provider is a separate copy.
struct ExportPicker: View {
  let urls: [URL]
  @Environment(\.dismiss) private var dismiss
  @State private var checked = false
  @State private var approved = false
  var body: some View {
    Group {
      if approved {
        NativeExportPicker(urls: urls)
      } else if !checked {
        ProgressView(tr("检查文件信息…"))
      } else {
        NavigationStack {
          VStack(alignment: .leading, spacing: 20) {
            Label(tr("此文件包含 Apple 附加信息"), systemImage: "doc.badge.gearshape").font(.headline)
            Text(tr("系统文件提供商可能无法保留资源分支或 Finder 信息。导出后文件内容可用，但相关 Apple 信息可能丢失；应用内下载的原件会保留。"))
            Button(tr("继续导出副本")) { approved = true }.buttonStyle(.borderedProminent)
            Button(tr("保留原件，暂不导出")) { dismiss() }
          }.padding().navigationTitle(tr("导出文件"))
        }
      }
    }.task {
      let paths = urls
      let needs = await Task.detached { AppleFileMetadata.needsConfirmation(paths) }.value
      approved = !needs
      checked = true
    }
  }
}
