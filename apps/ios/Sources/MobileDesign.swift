import SwiftUI

/// Shared mobile chrome. Monitoring owns its existing dashboard appearance.
struct SettingsLabel: View {
  let title: String
  let icon: String
  var color: Color = .gray
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon).font(.system(size: MobileDesign.iconSize, weight: .medium))
        .foregroundStyle(.white).frame(width: MobileDesign.iconTile, height: MobileDesign.iconTile)
        .background(color, in: RoundedRectangle(cornerRadius: MobileDesign.iconRadius))
      Text(tr(title)).foregroundStyle(.primary)
    }.padding(.vertical, 3)
  }
}

struct SettingsHome: View {
  var body: some View {
    List {
      Section(tr("偏好设置")) {
        NavigationLink {
          GeneralSettings()
        } label: {
          SettingsLabel(title: "通用", icon: "slider.horizontal.3")
        }.accessibilityIdentifier("settings-general")
        NavigationLink {
          GlobalAISettings()
        } label: {
          SettingsLabel(title: "AI", icon: "sparkles", color: .blue)
        }.accessibilityIdentifier("settings-ai")
      }
      Section(tr("连接与工具")) {
        NavigationLink {
          RecordsList(collection: "credentials", title: "凭证与密钥")
        } label: {
          SettingsLabel(title: "凭证与密钥", icon: "key", color: .orange)
        }
        NavigationLink {
          RecordsList(collection: "proxies", title: "代理配置")
        } label: {
          SettingsLabel(title: "代理配置", icon: "network", color: .blue)
        }
        NavigationLink {
          ToolSettings()
        } label: {
          SettingsLabel(title: "工具与快捷键", icon: "wrench", color: .purple)
        }
      }
      Section(tr("数据与支持")) {
        NavigationLink {
          MobileDataSyncSettings()
        } label: {
          SettingsLabel(title: "数据同步", icon: "arrow.triangle.2.circlepath.icloud", color: .blue)
        }.accessibilityIdentifier("settings-sync")
        NavigationLink {
          TransferHistoryView()
        } label: {
          SettingsLabel(title: "传输记录", icon: "arrow.up.arrow.down", color: .green)
        }
        NavigationLink {
          BackupView()
        } label: {
          SettingsLabel(title: "备份与恢复", icon: "archivebox", color: .blue)
        }
        NavigationLink {
          AboutSettings()
        } label: {
          SettingsLabel(title: "关于 TermPilot", icon: "info.circle")
        }.accessibilityIdentifier("settings-about")
      }
      Section {
        Text(
          "TermPilot · "
            + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        )
        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
      }
    }.listStyle(.insetGrouped).navigationTitle(tr("设置"))
  }
}

struct GeneralSettings: View {
  @EnvironmentObject var model: AppModel
  @AppStorage("TermPilot.language") private var language = "zh-Hans"
  @AppStorage("TermPilot.theme") private var theme = "dark"
  @AppStorage("TermPilot.fps") private var fps = 60
  @AppStorage("TermPilot.videoCodec") private var videoCodec = "h264"
  @AppStorage("TermPilot.fontSize") private var fontSize = 14.0
  var body: some View {
    Form {
      Section(tr("显示")) {
        NavigationLink {
          Form {
            Section {
              Text("root@home ~ $ uptime\nup 12 days, load average: 0.12")
                .font(.system(.callout, design: .monospaced)).padding(.vertical, 12)
            }
            Picker(tr("外观"), selection: mobileSyncedPreference($theme,"theme",model:model)) {
              Text(tr("深色")).tag("dark")
              Text(tr("浅色")).tag("light")
              Text(tr("跟随系统")).tag("system")
            }.pickerStyle(.inline)
          }.navigationTitle(tr("外观")).navigationBarTitleDisplayMode(.inline)
        } label: {
          LabeledContent(
            tr("外观"), value: tr(theme == "dark" ? "深色" : theme == "light" ? "浅色" : "跟随系统"))
        }
        Picker(tr("语言"), selection: mobileSyncedPreference($language,"language",model:model)) {
          Text("简体中文").tag("zh-Hans")
          Text("English").tag("en")
          Text(tr("跟随系统")).tag("system")
        }.pickerStyle(.navigationLink)
      }
      Section(tr("会话")) {
        NavigationLink {
          Form {
            Section(tr("预览")) {
              Text("root@home ~ $ ls\nDocuments  Downloads").font(
                .system(size: fontSize, design: .monospaced)
              ).padding(.vertical, 12)
            }
            Section(tr("文字")) {
              HStack {
                Text(tr("字号"))
                Spacer()
                Text("\(Int(fontSize)) pt").foregroundStyle(.secondary)
              }
              Slider(value: mobileSyncedPreference($fontSize,"fontSize",model:model), in: 10...28, step: 1).accessibilityLabel(tr("终端字号"))
            }
            Section { Picker(tr("Apple 高性能视频编码"), selection: mobileSyncedPreference($videoCodec,"videoCodec",model:model)) {
              Text("H.264").tag("h264"); Text("H.265").tag("h265")
            }.pickerStyle(.navigationLink) } footer: { Text(tr("用于 Apple 高性能屏幕共享，下次连接时生效。")) }
            Section(tr("输入")) { NavigationLink(tr("快捷键栏")) { KeyPreferencesView() } }
          }.navigationTitle(tr("终端")).navigationBarTitleDisplayMode(.inline)
        } label: {
          LabeledContent(tr("终端"), value: "\(Int(fontSize)) pt")
        }
        Picker(tr("远程桌面帧率上限"), selection: mobileSyncedPreference($fps,"fps",model:model)) {
          Text("30 FPS").tag(30)
          Text("60 FPS").tag(60)
        }.pickerStyle(.navigationLink)
      }
      Section {
        Text(tr("后台连接受系统限制。返回后请确认会话状态；不会自动重放命令。"))
          .font(.footnote).foregroundStyle(.secondary)
      }
    }.navigationTitle(tr("通用")).navigationBarTitleDisplayMode(.inline)
      .onChange(of: fps) { _, value in
        for session in model.sessions where session.protocolKind != "ssh" {
          model.attempt { try await model.send(session.id, ["kind": "frameRate", "fps": value]) }
        }
      }
  }
}

struct ToolSettings: View {
  var body: some View {
    List {
      Section(tr("输入")) { NavigationLink(tr("快捷键栏")) { KeyPreferencesView() } }
      Section(tr("保存的配置")) {
        ForEach(
          [
            ("groups", "主机分组", "folder"), ("scripts", "脚本", "terminal"),
            ("notes", "笔记", "note.text"), ("forwards", "端口转发", "arrow.left.arrow.right"),
          ], id: \.0
        ) { key, title, icon in
          NavigationLink {
            RecordsList(collection: key, title: title)
          } label: {
            Label(tr(title), systemImage: icon)
          }
        }
      }
    }.listStyle(.insetGrouped).navigationTitle(tr("工具与快捷键")).navigationBarTitleDisplayMode(.inline)
  }
}

struct AboutSettings: View {
  @State private var showsLicense = false
  var body: some View {
    List {
      Section {
        LabeledContent(tr("应用名称"), value: "TermPilot")
        LabeledContent(
          tr("版本"),
          value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
      }
      Section(tr("开源许可")) {
        Button("GNU General Public License v3.0") { showsLicense = true }
          .accessibilityIdentifier("open-gpl-license")
      }
    }.listStyle(.insetGrouped).navigationTitle(tr("关于 TermPilot")).navigationBarTitleDisplayMode(
      .inline)
      .sheet(isPresented: $showsLicense) { GPLLicenseView() }
  }
}

private struct GPLLicenseView: View {
  @Environment(\.dismiss) private var dismiss
  private let text = Bundle.main.url(forResource: "GPL-3.0", withExtension: "txt")
    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("GNU General Public License v3.0").font(.headline)
          Text(verbatim: text ?? tr("无法加载许可文本。"))
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("gpl-license-text")
        }.frame(maxWidth: .infinity, alignment: .leading).padding()
      }
      .navigationTitle(tr("开源许可")).navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button(tr("完成")) { dismiss() }.accessibilityIdentifier("close-gpl-license")
        }
      }
    }.presentationDetents([.large])
  }
}
