import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FilesView: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  @State private var edit: FileEdit?
  @State private var importing = false
  @State private var exporting = false
  @State private var newFolder = false
  @State private var folderName = ""
  @State private var targetPath = ""
  @State private var exportURLs: [URL] = []
  var body: some View {
    VStack(spacing: 0) {
      if session.protocolKind == "ssh" {
        HStack {
          Image(systemName: "folder")
          TextField(tr("远端路径"), text: $targetPath).textInputAutocapitalization(.never)
            .autocorrectionDisabled().onSubmit {
              model.attempt { try await model.list(session, path: targetPath) }
            }
          Button {
            importing = true
          } label: {
            Image(systemName: "square.and.arrow.up")
          }
          Button {
            newFolder = true
          } label: {
            Image(systemName: "folder.badge.plus")
          }
          Button {
            model.attempt { try await model.list(session) }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }.padding()
      }
      if session.protocolKind == "ssh" {
        List {
          Button(tr("上级目录")) {
            model.attempt {
              try await model.list(
                session, path: (session.path as NSString).deletingLastPathComponent)
            }
          }
          ForEach(session.entries, id: \.selfID) { entry in
            HStack {
              Image(systemName: entry.text("kind") == "directory" ? "folder" : "doc")
                .foregroundStyle(.tint)
              Text(entry.text("name")).lineLimit(2)
              Spacer()
              Text(
                ByteCountFormatter.string(
                  fromByteCount: Int64(entry.number("size")), countStyle: .file)
              ).font(.caption).foregroundStyle(.secondary)
            }.onDrag {
              let provider = NSItemProvider()
              let type =
                entry.text("kind") == "directory"
                ? UTType.folder
                : UTType(filenameExtension: (entry.text("name") as NSString).pathExtension) ?? .data
              provider.suggestedName = entry.text("name")
              provider.registerFileRepresentation(
                forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all
              ) { complete in
                let progress = Progress(totalUnitCount: 1)
                model.attempt {
                  do {
                    let folder = model.runtime!.directory.appendingPathComponent(
                      "Transfers/" + UUID().uuidString)
                    try FileManager.default.createDirectory(
                      at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent(entry.text("name"))
                    try await model.transfer(
                      session, upload: false, local: file, remote: remote(entry.text("name")))
                    progress.completedUnitCount = 1
                    complete(file, false, nil)
                  } catch { complete(nil, false, error) }
                }
                return progress
              }
              return provider
            }.contentShape(Rectangle()).onTapGesture {
              if entry.text("kind") == "directory" {
                model.attempt { try await model.list(session, path: remote(entry.text("name"))) }
              }
            }.contextMenu {
              Button(tr("下载")) { download(entry) }
              Button(tr("重命名")) {
                edit = FileEdit(operation: "rename", path: remote(entry.text("name")))
              }
              Button(tr("权限")) {
                edit = FileEdit(operation: "chmod", path: remote(entry.text("name")))
              }
              if entry.text("kind") == "file" {
                Button(tr("编辑文本")) {
                  edit = FileEdit(operation: "writeText", path: remote(entry.text("name")))
                }
              }
              Button(tr("删除"), role: .destructive) {
                edit = FileEdit(operation: "delete", path: remote(entry.text("name")))
              }
            }
          }
        }
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text(session.protocolKind == "rdp" ? tr("文件剪贴板") : tr("远程文件传输")).font(.title3)
            Text(
              session.protocolKind == "rdp"
                ? tr("选择本地文件后，在远端文件夹中粘贴。远端复制的文件下载完成后，可导出到系统“文件”。")
                : tr("先将文件拖入远端桌面；本地文件选择与系统拖放使用同一个传输通道。"))
            if session.protocolKind == "rdp" || session.host.text("mode") == "highPerformance" {
              Button(tr("选择本地文件")) { importing = true }.buttonStyle(.borderedProminent)
            } else {
              Text(tr("普通 VNC 支持文本剪贴板；该协议不提供此文件通道。"))
            }
            if session.host.text("mode") == "highPerformance" {
              Button(tr("读取远端拖拽文件")) {
                model.attempt { try await model.send(session.id, ["kind": "dragRequest"]) }
              }
              ForEach(session.remoteFiles, id: \.self) { source in
                Button(trf("下载 {}", (source as NSString).lastPathComponent)) {
                  model.attempt {
                    let name = (source as NSString).lastPathComponent
                    guard !name.isEmpty, name != ".", name != ".." else {
                      throw MobileError(message: tr("文件名称无效"))
                    }
                    let folder = model.runtime!.directory.appendingPathComponent(
                      "Transfers/\(UUID().uuidString)")
                    try FileManager.default.createDirectory(
                      at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent(name)
                    let id = UUID().uuidString
                    session.remoteDownloads[id] = file
                    try await model.send(
                      session.id,
                      [
                        "kind": "fileDownload", "requestID": id, "source": source,
                        "destination": file.path,
                      ])
                  }
                }
              }
            }
            if !session.previewFiles.isEmpty {
              Button(tr("导出已下载文件")) {
                exportURLs = session.previewFiles
                exporting = true
              }
            }
          }.padding()
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }.onDrop(of: [UTType.fileURL, UTType.item], isTargeted: nil) { providers in
      model.attempt {
        guard session.connected else { throw MobileError(message: tr("请先连接服务器")) }
        for provider in providers {
          let file = try await FileStager.receive(provider, root: model.runtime!.directory)
          if session.protocolKind == "ssh" {
            try await model.transfer(
              session, upload: true, local: file, remote: remote(file.lastPathComponent))
          } else if session.protocolKind == "rdp" {
            try await model.send(
              session.id,
              ["kind": "clipboardOffer", "offerId": UUID().uuidString, "paths": [file.path]])
          } else if session.host.text("mode") == "highPerformance" {
            session.localDragPaths.append(file.path)
          }
        }
        if !session.localDragPaths.isEmpty {
          try await model.send(session.id, ["kind": "dragEnter", "paths": session.localDragPaths])
          session.activePanel = "terminal"
        }
      }
      return session.protocolKind == "ssh" || session.protocolKind == "rdp"
        || session.host.text("mode") == "highPerformance"
    }.onAppear { targetPath = session.path }.onChange(of: session.path) { _, p in targetPath = p }
      .fileImporter(
        isPresented: $importing, allowedContentTypes: [.item, .folder],
        allowsMultipleSelection: true
      ) { result in
        model.attempt {
          let urls = try result.get()
          var staged: [String] = []
          for url in urls {
            let destination = try await stage(url)
            if session.protocolKind == "ssh" {
              try await model.transfer(
                session, upload: true, local: destination,
                remote: remote(destination.lastPathComponent))
            } else {
              staged.append(destination.path)
            }
          }
          if !staged.isEmpty {
            if session.protocolKind == "rdp" {
              try await model.send(
                session.id,
                ["kind": "clipboardOffer", "offerId": UUID().uuidString, "paths": staged])
            } else {
              try await model.send(session.id, ["kind": "dragEnter", "paths": staged])
              session.localDragPaths = staged
              session.activePanel = "terminal"
            }
          }
        }
      }
      .fullScreenCover(item: $edit) { FileEditor(session: session, edit: $0) }
      .sheet(isPresented: $exporting) { ExportPicker(urls: exportURLs) }
      .alert(tr("新建文件夹"), isPresented: $newFolder) {
        TextField(tr("名称"), text: $folderName)
        Button(tr("取消"), role: .cancel) {}
        Button(tr("创建")) {
          model.attempt {
            guard !folderName.isEmpty, !folderName.contains("/"), folderName != ".",
              folderName != ".."
            else { throw MobileError(message: tr("文件夹名称无效")) }
            _ = try await model.files(session, ["action": "mkdir", "path": remote(folderName)])
            try await model.list(session)
          }
        }
      }
  }
  private func remote(_ name: String) -> String {
    session.path.hasSuffix("/") ? session.path + name : session.path + "/" + name
  }
  private func stage(_ url: URL) async throws -> URL {
    let root = model.runtime!.directory
    return try await Task.detached { try FileStager.copy(url, root: root) }.value
  }
  private func download(_ entry: JSON) {
    model.attempt {
      let directory = model.runtime!.directory.appendingPathComponent(
        "Transfers/\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(entry.text("name"))
      try await model.transfer(
        session, upload: false, local: url, remote: remote(entry.text("name")))
      exportURLs = [url]
      exporting = true
    }
  }
}
struct NativeExportPicker: UIViewControllerRepresentable {
  let urls: [URL]
  func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
    UIDocumentPickerViewController(forExporting: urls, asCopy: true)
  }
  func updateUIViewController(_ view: UIDocumentPickerViewController, context: Context) {}
}
struct TransferTray: View {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  @State private var expanded = false
  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      ScrollView {
        VStack(spacing: 12) {
          ForEach(session.transfers.keys.sorted(), id: \.self) { id in
            let t = session.transfers[id] ?? [:]
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(t.text("name", tr("文件"))).lineLimit(1)
                Spacer()
                if TransferState.active(t.text("status")) {
                  Button {
                    control(id, TransferState.paused(t.text("status")) ? "resume" : "pause")
                  } label: {
                    Image(
                      systemName: TransferState.paused(t.text("status"))
                        ? "play.fill" : "pause.fill")
                  }
                  Button(role: .destructive) {
                    control(id, "cancel")
                  } label: {
                    Image(systemName: "xmark")
                  }
                } else {
                  Button {
                    session.transfers.removeValue(forKey: id)
                  } label: {
                    Image(systemName: "checkmark")
                  }
                }
              }
              ProgressView(
                value: Double(t.number("transferred")), total: Double(max(1, t.number("total"))))
              HStack {
                Text(tr(TransferState.label(t.text("status"))))
                Text("\(t.number("rate")/1024) KiB/s")
                Spacer()
                Text("\(t.number("transferred")/1024) / \(t.number("total")/1024) KiB")
              }.font(.caption).foregroundStyle(.secondary)
            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }.frame(maxHeight: 200)
    } label: {
      Label(trf("文件传输 · {}", String(session.transfers.count)), systemImage: "arrow.up.arrow.down")
        .font(.callout)
    }.padding(10).background(.regularMaterial)
  }
  private func control(_ id: String, _ action: String) {
    model.attempt { try await model.controlTransfer(session, id: id, action: action) }
  }
}
