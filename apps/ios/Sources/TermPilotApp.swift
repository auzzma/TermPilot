import SwiftUI

@main struct TermPilotApp: App {
  @StateObject private var model = AppModel()
  @AppStorage("TermPilot.language") private var language = "zh-Hans"
  @AppStorage("TermPilot.theme") private var theme = "dark"
  @Environment(\.scenePhase) private var phase
  init() { _ = TransferBackground.shared }
  var body: some Scene {
    WindowGroup {
      appContent
        .environment(
          \.locale, Locale(identifier: language == "system" ? Locale.current.identifier : language)
        )
        .preferredColorScheme(theme == "system" ? nil : theme == "light" ? .light : .dark)
        .onChange(of: phase) { _, value in model.lifecycle(value) }
    }
  }
  @ViewBuilder private var appContent: some View {
    #if DEBUG
    if let kind = ProcessInfo.processInfo.environment["TERMPILOT_KEYBOARD_UI_FIXTURE"] {
      KeyboardInteractionFixture(kind: kind)
    } else {
      RootView().environmentObject(model).task { await model.start() }
    }
    #else
    RootView().environmentObject(model).task { await model.start() }
    #endif
  }
}
