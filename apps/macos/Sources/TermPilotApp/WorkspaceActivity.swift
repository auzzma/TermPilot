import AppKit
import SwiftUI

@MainActor
final class WorkspaceActivity: ObservableObject {
    @Published var selected = false
    @Published var windowVisible = false
    var isActive: Bool { selected && windowVisible }
}

struct WorkspaceVisibilityReader: NSViewRepresentable {
    let activity: WorkspaceActivity
    func makeNSView(context: Context) -> Observer { Observer(activity: activity) }
    func updateNSView(_ view: Observer, context: Context) {}

    final class Observer: NSView {
        let activity: WorkspaceActivity
        init(activity: WorkspaceActivity) {
            self.activity = activity
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        deinit { NotificationCenter.default.removeObserver(self) }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(updateVisibility), name: name, object: window)
                }
            }
            updateVisibility()
        }
        @objc private func updateVisibility() {
            let visible = window.map { !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
            // AppKit can notify while SwiftUI is applying a view update.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activity.windowVisible != visible else { return }
                self.activity.windowVisible = visible
            }
        }
    }
}

struct HostRowHoverScope<Content: View>: View {
    @State private var hovered = false
    @State private var editHovered = false
    @ViewBuilder var content: (Bool, Binding<Bool>) -> Content
    var body: some View {
        content(hovered, $editHovered).onHover {
            hovered = $0
            if !$0 { editHovered = false }
        }
    }
}
