import SwiftUI

let mobileTools: [(String,String,String)] = [
  ("files","文件","folder"),("monitor","监控","waveform.path.ecg"),("scripts","脚本","terminal"),
  ("tmux","tmux","square.grid.2x2"),("commands","历史","clock.arrow.circlepath"),
  ("notes","笔记","note.text"),("forwards","转发","arrow.left.arrow.right")
]
struct ToolDock: View {
  @Binding var selected: String
  let ssh: Bool
  var group: String { ["monitor","processes","docker","images"].contains(selected) ? "monitor" : selected == "history" ? "commands" : selected }
  var body: some View {
    VStack(spacing:0) {
      Divider()
      if group == "monitor" {
        Picker(tr("监控"),selection:$selected) { Text(tr("概览")).tag("monitor");Text(tr("进程")).tag("processes");Text("Docker").tag("docker");Text(tr("镜像")).tag("images") }.pickerStyle(.segmented).padding(.horizontal,12).padding(.vertical,8)
      } else if group == "commands" {
        Picker(tr("历史"),selection:$selected) { Text(tr("命令历史")).tag("commands");Text(tr("连接历史")).tag("history") }.pickerStyle(.segmented).padding(.horizontal,12).padding(.vertical,8)
      }
      GeometryReader { geometry in
      ScrollView(.horizontal,showsIndicators:false) {
        HStack(spacing:2) {
          ForEach(mobileTools,id:\.0) { key,title,icon in
            Button { selected=key } label: {
              VStack(spacing:5) { Image(systemName:icon).font(.system(size:21));Text(tr(title)).font(.caption2) }
                .frame(width:min(80,max(48,(geometry.size.width-32)/7)),height:56).foregroundStyle(group==key ? Color.accentColor : .secondary)
                .background(group==key ? Color.accentColor.opacity(0.13) : .clear,in:RoundedRectangle(cornerRadius:12))
            }.buttonStyle(.plain).disabled(!ssh && key != "files").accessibilityIdentifier("tool-"+key)
          }
        }.padding(.horizontal,10).padding(.vertical,6)
      }
      }.frame(height:68)
    }.background(.regularMaterial).accessibilityIdentifier("tool-bottom-navigation")
  }
}
