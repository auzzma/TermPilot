import SwiftUI

struct AISettingsHome: View {
  @EnvironmentObject var model: AppModel
  let session: MobileSession
  var body: some View {
    List {
      Section(tr("模型与助手")) {
        NavigationLink {
          AIProvidersList(session: session)
        } label: {
          SettingsLabel(title: "提供商", icon: "cloud.fill", color: .blue)
        }
        NavigationLink {
          List {
            Section(tr("内置助手")) {
              Label("TermPilot Agent", systemImage: "sparkles")
              Text(tr("使用提供商模型分析服务器、执行命令和调用工具。")).foregroundStyle(.secondary)
            }
            Section {
              LabeledContent("Codex / Claude Code", value: tr("仅桌面端"))
            } header: {
              Text(tr("外部 Agent"))
            } footer: {
              Text(tr("移动端不运行本地外部 Agent。请在桌面端配置与使用。"))
            }
          }.listStyle(.insetGrouped).navigationTitle("Agent").navigationBarTitleDisplayMode(.inline)
        } label: {
          SettingsLabel(title: "Agent", icon: "sparkles", color: .purple)
        }
      }
      Section(tr("能力与权限")) {
        NavigationLink {
          List {
            Section {
              Label(tr("终端上下文"), systemImage: "terminal")
              Label(tr("命令执行与任务管理"), systemImage: "wrench.and.screwdriver")
            } header: {
              Text(tr("会话工具"))
            } footer: {
              Text(tr("工具只作用于当前连接的服务器，并遵循命令审批设置。"))
            }
            Section {
              LabeledContent(tr("MCP 服务"), value: tr("仅桌面端"))
            } header: {
              Text("MCP")
            } footer: {
              Text(tr("移动端暂不支持启用 MCP 服务。"))
            }
          }.listStyle(.insetGrouped).navigationTitle(tr("工具接入")).navigationBarTitleDisplayMode(
            .inline)
        } label: {
          SettingsLabel(title: "工具接入", icon: "puzzlepiece.extension.fill", color: .orange)
        }
        NavigationLink {
          AIBehaviorSettings(session: session, section: "search")
        } label: {
          SettingsLabel(title: "网络搜索", icon: "globe", color: .cyan)
        }
        NavigationLink {
          AIBehaviorSettings(session: session)
        } label: {
          SettingsLabel(title: "行为与安全", icon: "shield.fill", color: .green)
        }
      }
      Section {
      } footer: {
        Text(tr("AI 对话绑定当前服务器。配置可在所有会话中使用。"))
      }
    }.listStyle(.insetGrouped).navigationTitle(tr("AI 设置")).navigationBarTitleDisplayMode(.inline)
  }
}
private struct ProviderSelection: Identifiable { let id: String }
struct AIProvidersList: View {
  @EnvironmentObject var model: AppModel
  let session: MobileSession
  @State private var edit: ProviderSelection?
  var body: some View {
    List {
      Section(tr("已保存的提供商")) {
        if model.aiSettings.array("providers").isEmpty {
          ContentUnavailableView(
            tr("暂无提供商"), systemImage: "cloud", description: Text(tr("添加 API 配置后即可开始对话")))
        }
        ForEach(model.aiSettings.array("providers"), id: \.selfID) { provider in
          Button {
            edit = ProviderSelection(id: provider.text("id"))
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(provider.text("name")).foregroundStyle(.primary)
                Text(provider.text("model")).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              if provider.text("id") == model.aiSettings.text("selected") {
                Text(tr("默认")).font(.caption).foregroundStyle(.secondary)
              }
              Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
          }
        }
      }
      Section {
        Button {
          edit = ProviderSelection(id: "new")
        } label: {
          Label(tr("新增提供商"), systemImage: "plus")
        }
      }
    }.listStyle(.insetGrouped).navigationTitle(tr("提供商")).navigationBarTitleDisplayMode(.inline)
      .sheet(item: $edit) { selection in
        ProviderEditor(session: session, initialProviderID: selection.id)
          .presentationSizingIfAvailable()
      }
  }
}
