import AppKit
import SwiftUI

/// Keep the native drop destination outside the SwiftUI List/NSHostingView.
/// Lists rebuild their native children when switching directories or view modes.
struct SFTPFileDropArea<Content: View>: NSViewRepresentable {
    let isEnabled: Bool
    let onTargeted: (Bool) -> Void
    let onDrop: ([URL]) -> Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> SFTPFileDropView {
        let view = SFTPFileDropView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: SFTPFileDropView, context: Context) {
        view.host.rootView = AnyView(content().environment(\.self, context.environment))
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        view.isEnabled = isEnabled
    }

    static func dismantleNSView(_ view: SFTPFileDropView, coordinator: ()) {
        view.isEnabled = false
        view.onTargeted = nil
        view.onDrop = nil
    }
}

@MainActor
final class SFTPFileDropView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    var onTargeted: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Bool)?
    var isEnabled = false {
        didSet {
            if oldValue != isEnabled { updateRegistration() }
        }
    }
    private var isTargeted = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRegistration()
    }

    private func updateRegistration() {
        if isEnabled, window != nil {
            registerForDraggedTypes([.fileURL])
        } else {
            unregisterDraggedTypes()
            setTargeted(false)
        }
    }

    private func setTargeted(_ value: Bool) {
        guard isTargeted != value else { return }
        isTargeted = value
        onTargeted?(value)
    }

    private func canAccept(_ sender: any NSDraggingInfo) -> Bool {
        isEnabled && window != nil && !isHiddenOrHasHiddenAncestor
            && sender.draggingSourceOperationMask.contains(.copy)
            && !Self.fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = canAccept(sender)
        setTargeted(accepted)
        return accepted ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { setTargeted(false) }
    override func draggingEnded(_ sender: any NSDraggingInfo) { setTargeted(false) }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer { setTargeted(false) }
        guard canAccept(sender) else { return false }
        return onDrop?(Self.fileURLs(from: sender.draggingPasteboard)) ?? false
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        var seen = Set<URL>()
        return urls.compactMap { url in
            guard let local = SFTPDroppedFileURL.decode(url as NSURL) else { return nil }
            let normalized = local.standardizedFileURL
            return seen.insert(normalized).inserted ? normalized : nil
        }
    }
}
