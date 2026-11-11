import AppKit
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

public struct ScreenSharingSurface: NSViewRepresentable {
    public let runtime: ScreenSharingSessionRuntime
    public let isActive: Bool
    public var onFocus: (() -> Void)?
    public init(runtime: ScreenSharingSessionRuntime, isActive: Bool, onFocus: (() -> Void)? = nil) {
        self.runtime = runtime; self.isActive = isActive; self.onFocus = onFocus
    }
    public func makeNSView(context: Context) -> ScreenSharingMetalView {
        let view = ScreenSharingMetalView(runtime: runtime)
        view.clipboardPaneActive = isActive
        view.isHidden = !isActive
        view.onFocus = onFocus
        if !view.isRendererReady { Task { @MainActor in runtime.renderingUnavailable() } }
        return view
    }
    public func updateNSView(_ view: ScreenSharingMetalView, context: Context) {
        view.runtime = runtime
        view.preferredFramesPerSecond = runtime.frameRate
        view.onFocus = onFocus
        view.isPaused = !isActive
        // Native drag hit testing must see the same tab visibility as SwiftUI.
        view.isHidden = !isActive
        view.clipboardPaneActive = isActive
        view.updateClipboardFocus()
        if !isActive { view.releaseInput() }
    }
    public static func dismantleNSView(_ view: ScreenSharingMetalView, coordinator: ()) {
        view.releaseInput(); view.isPaused = true
        view.clipboardPaneActive = false
        view.updateClipboardFocus()
    }
}

enum ScreenSharingGeometry {
    static func contentRect(in bounds: CGRect, remoteSize: CGSize = CGSize(width: 1920, height: 1080)) -> CGRect {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return .zero }
        let scale = max(0, min(bounds.width / remoteSize.width, bounds.height / remoteSize.height))
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    static func remotePoint(_ point: CGPoint, in bounds: CGRect, remoteSize: CGSize = CGSize(width: 1920, height: 1080), clamp: Bool = false) -> CGPoint? {
        let rect = contentRect(in: bounds, remoteSize: remoteSize)
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return nil }
        return CGPoint(x: min(remoteSize.width - 1, max(0, (point.x - rect.minX) / rect.width * remoteSize.width)),
                       y: min(remoteSize.height - 1, max(0, (point.y - rect.minY) / rect.height * remoteSize.height)))
    }
}

@MainActor
public final class ScreenSharingMetalView: MTKView, MTKViewDelegate, NSDraggingSource, @preconcurrency NSTextInputClient {
    var runtime: ScreenSharingSessionRuntime {
        didSet {
            if runtime !== oldValue { scrollState.reset() }
            updateFileDropRegistration()
        }
    }
    var onFocus: (() -> Void)?
    var clipboardPaneActive = true {
        didSet { updateFileDropRegistration() }
    }
    private var renderPipeline: (any MTLRenderPipelineState)?
    private var commandQueue: (any MTLCommandQueue)?
    private var tiles: [Int: (ScreenSharingMessage, [any MTLTexture])] = [:]
    private var lastMailbox: ScreenSharingMailbox?
    private var hasUnpresentedFrame = false
    private var markedInput = NSAttributedString(string: "")
    private var inputSelection = NSRange(location: 0, length: 0)
    private var keyboard = ScreenSharingKeyboardState()
    private var scrollState = ScreenSharingScrollState()
    private var buttons = 0
    private var pointerTracking: NSTrackingArea?
    private var incomingDrag = false
    private var outgoingDrag = false
    private var requestedRemoteDrag = false
    private var lastDragEvent: NSEvent?
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    var isRendererReady: Bool { renderPipeline != nil && commandQueue != nil }

    init(runtime: ScreenSharingSessionRuntime) {
        self.runtime = runtime
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // RDP, VNC and high-performance screen sharing all use this display link.
        preferredFramesPerSecond = runtime.frameRate
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.02, 0.025, 0.035, 1)
        framebufferOnly = true
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        delegate = self
        runtime.remoteDragChanged = { [weak self] in self?.beginRemoteFileDragIfReady() }
        guard let device else { runtime.videoDiagnostics.videoError = "Metal unavailable"; return }
        runtime.videoDiagnostics.renderer = "Metal · \(device.name)"
        commandQueue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch { renderPipeline = nil; runtime.videoDiagnostics.videoError = "Metal pipeline initialization failed" }
        setAccessibilityLabel("Remote desktop")
    }
    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    public func draw(in view: MTKView) {
        if lastMailbox !== runtime.mailbox {
            tiles.removeAll(); lastMailbox = runtime.mailbox; hasUnpresentedFrame = false
        }
        runtime.playAudio()
        for frame in runtime.mailbox.takeFrames() {
            if let textures = textures(for: frame) {
                tiles[frame.header.tile!] = (frame.header, textures)
                hasUnpresentedFrame = true
            } else { runtime.videoDiagnostics.videoError = "Video texture upload failed" }
        }
        guard let renderPipeline, let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable, let buffer = commandQueue?.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(renderPipeline)
        let desktop = runtime.desktopSize
        let rect = ScreenSharingGeometry.contentRect(in: CGRect(origin: .zero, size: drawableSize), remoteSize: desktop)
        for index in tiles.keys.sorted() {
            let (header, textures) = tiles[index]!
            let top = index * header.height!
            guard Double(top) < desktop.height else { continue }
            encoder.setViewport(MTLViewport(originX: rect.minX,
                                            originY: rect.minY + Double(top) / desktop.height * rect.height,
                                            width: Double(header.width!) / desktop.width * rect.width,
                                            height: Double(header.height!) / desktop.height * rect.height,
                                            znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: max(0, Int(rect.minX)), y: max(0, Int(rect.minY)),
                                                 width: max(1, Int(rect.width)), height: max(1, Int(rect.height))))
            for (i, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: i) }
            var mode: UInt32 = header.pixelFormat == "bgrx" ? 2 : header.biplanar == true ? 1 : 0
            encoder.setFragmentBytes(&mode, length: 4, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding(); buffer.present(drawable); buffer.commit()
        if hasUnpresentedFrame {
            runtime.recordPresentedFrame()
            hasUnpresentedFrame = false
        }
    }

    private func textures(for frame: ScreenSharingFrame) -> [any MTLTexture]? {
        guard let device else { return nil }
        let h = frame.header
        if h.pixelFormat == "bgrx" {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: h.width!, height: h.height!, mipmapped: false)
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            frame.data.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, h.width!, h.height!), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!, bytesPerRow: h.yStride!)
            }
            return [texture, texture, texture]
        }
        let widths = [h.width!, h.chromaWidth!, h.chromaWidth!]
        let heights = [h.height!, h.chromaHeight!, h.chromaHeight!]
        let strides = [h.yStride!, h.uvStride!, h.uvStride!]
        let offsets = [0, h.yLength!, h.yLength! + h.uLength!]
        var result: [any MTLTexture] = []
        for i in 0..<(h.biplanar == true ? 2 : 3) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: i == 1 && h.biplanar == true ? .rg8Unorm : .r8Unorm,
                width: widths[i], height: heights[i], mipmapped: false)
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            frame.data.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, widths[i], heights[i]), mipmapLevel: 0,
                                withBytes: bytes.baseAddress!.advanced(by: offsets[i]), bytesPerRow: strides[i])
            }
            result.append(texture)
        }
        if result.count == 2 { result.append(result[1]) }
        return result
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); pointerTracking = tracking
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFileDropRegistration()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(clipboardFocusChanged), name: name, object: window)
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(clipboardFocusChanged), name: name, object: nil)
            }
        } else { releaseInput() }
        updateClipboardFocus()
    }
    @objc private func clipboardFocusChanged(_ notification: Notification) {
        if notification.name == NSWindow.didResignKeyNotification || notification.name == NSApplication.didResignActiveNotification {
            releaseInput()
        }
        updateClipboardFocus()
    }
    func updateClipboardFocus() {
        runtime.setClipboardFocused(clipboardPaneActive && window?.isKeyWindow == true && NSApplication.shared.isActive)
    }
    private var acceptsIncomingFileDrops: Bool {
        clipboardPaneActive && runtime.supportsFileTransfer && window != nil
    }
    private func updateFileDropRegistration() {
        // SwiftUI retains inactive tab surfaces. Opacity/allowsHitTesting do
        // not unregister an AppKit dragging destination on those native views.
        if acceptsIncomingFileDrops {
            if !registeredDraggedTypes.contains(.fileURL) {
                registerForDraggedTypes([.fileURL])
            }
        } else {
            if !registeredDraggedTypes.isEmpty { unregisterDraggedTypes() }
            if incomingDrag { runtime.cancelLocalDrag(); incomingDrag = false }
        }
    }
    public override func mouseDown(with event: NSEvent) {
        runtime.remoteDragPaths = []
        requestedRemoteDrag = false; lastDragEvent = nil
        onFocus?(); window?.makeFirstResponder(self); buttons |= 1; pointer(event)
    }
    public override func mouseUp(with event: NSEvent) {
        lastDragEvent = nil
        guard !outgoingDrag else { return }
        buttons &= ~1; pointer(event, clamp: true)
    }
    public override func rightMouseDown(with event: NSEvent) {
        onFocus?(); window?.makeFirstResponder(self); buttons |= 2; pointer(event)
    }
    public override func rightMouseUp(with event: NSEvent) { buttons &= ~2; pointer(event, clamp: true) }
    public override func otherMouseDown(with event: NSEvent) {
        onFocus?(); window?.makeFirstResponder(self); buttons |= 4; pointer(event)
    }
    public override func otherMouseUp(with event: NSEvent) { buttons &= ~4; pointer(event, clamp: true) }
    public override func mouseMoved(with event: NSEvent) { pointer(event) }
    public override func mouseDragged(with event: NSEvent) {
        guard !outgoingDrag else { return }
        lastDragEvent = event
        if ScreenSharingGeometry.remotePoint(convert(event.locationInWindow, from: nil), in: bounds, remoteSize: runtime.desktopSize) == nil {
            beginRemoteFileDragIfReady()
            if runtime.supportsFileTransfer && !outgoingDrag && !requestedRemoteDrag {
                requestedRemoteDrag = true; runtime.requestRemoteDrag()
            }
            return
        }
        pointer(event)
    }
    public override func rightMouseDragged(with event: NSEvent) { pointer(event, clamp: true) }
    public override func otherMouseDragged(with event: NSEvent) { pointer(event, clamp: true) }
    public override func scrollWheel(with event: NSEvent) {
        guard ScreenSharingGeometry.remotePoint(convert(event.locationInWindow, from: nil), in: bounds,
                                                 remoteSize: runtime.desktopSize) != nil else {
            scrollState.reset(); return
        }
        pointer(event)
        if runtime.isRDP || runtime.isStandardVNC {
            let amount = event.scrollingDeltaY
            if amount != 0 { runtime.sendScroll(amount > 0 ? -1 : 1) }
        } else {
            for amount in scrollState.commands(for: event) { runtime.sendScroll(amount) }
        }
    }
    private func pointer(_ event: NSEvent, clamp: Bool = false) {
        guard let point = ScreenSharingGeometry.remotePoint(convert(event.locationInWindow, from: nil), in: bounds, remoteSize: runtime.desktopSize, clamp: clamp) else { return }
        runtime.sendPointer(x: Int(point.x), y: Int(point.y), buttons: buttons)
    }
    public override func keyDown(with event: NSEvent) {
        if runtime.isRDP, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control),
           hasMarkedText() || Self.keysyms[event.keyCode] == nil {
            interpretKeyEvents([event]); return
        }
        let key: UInt32?
        if let special = Self.keysyms[event.keyCode] { key = special }
        else if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first {
            key = scalar.value <= 0xFF ? scalar.value : scalar.value | 0x01000000
        } else { key = nil }
        send(keyboard.keyDown(code: event.keyCode, keysym: key, flags: event.modifierFlags))
    }
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        unmarkText()
        if !text.isEmpty { runtime.sendText(text) }
    }
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedInput = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        inputSelection = selectedRange
    }
    public func unmarkText() { markedInput = NSAttributedString(string: ""); inputSelection = NSRange(location: 0, length: 0) }
    public func selectedRange() -> NSRange { inputSelection }
    public func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedInput.length) : NSRange(location: NSNotFound, length: 0) }
    public func hasMarkedText() -> Bool { markedInput.length > 0 }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let selected = NSIntersectionRange(range, NSRange(location: 0, length: markedInput.length))
        actualRange?.pointee = selected
        return selected.length > 0 ? markedInput.attributedSubstring(from: selected) : nil
    }
    public func characterIndex(for point: NSPoint) -> Int { 0 }
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let rect = convert(NSRect(x: bounds.midX, y: bounds.maxY - 32, width: 1, height: 24), to: nil)
        return window?.convertToScreen(rect) ?? rect
    }
    public override func doCommand(by selector: Selector) {
        let names: [String: UInt32] = ["insertNewline:":0xff0d, "insertTab:":0xff09, "deleteBackward:":0xff08, "cancelOperation:":0xff1b]
        if let key = names[NSStringFromSelector(selector)] { runtime.sendKey(key, down: true); runtime.sendKey(key, down: false) }
        else { super.doCommand(by: selector) }
    }
    public override func keyUp(with event: NSEvent) {
        send(keyboard.keyUp(code: event.keyCode, flags: event.modifierFlags))
    }
    public override func flagsChanged(with event: NSEvent) {
        send(keyboard.updateModifiers(event.modifierFlags))
    }
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command) {
            // AppKit may consume the corresponding key-up for a menu shortcut.
            // Send a balanced key press now; a later physical key-up is ignored.
            keyDown(with: event)
            keyUp(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    public override func resignFirstResponder() -> Bool { releaseInput(); return super.resignFirstResponder() }
    @objc public func copy(_ sender: Any?) { commandShortcut(0x63) }
    @objc public func paste(_ sender: Any?) { commandShortcut(0x76) }
    @objc public func cut(_ sender: Any?) { commandShortcut(0x78) }
    public override func selectAll(_ sender: Any?) { commandShortcut(0x61) }
    private func commandShortcut(_ key: UInt32) {
        send(keyboard.updateModifiers(.command))
        runtime.sendKey(key, down: true)
        runtime.sendKey(key, down: false)
        send(keyboard.updateModifiers([]))
    }
    private func send(_ events: [ScreenSharingKeyStroke]) {
        events.forEach { runtime.sendKey($0.key, down: $0.down) }
    }
    func releaseInput() { runtime.releaseInput(); keyboard.reset(); scrollState.reset(); buttons = 0 }

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        runtime.recordFileDrag("localDragOffered", count: sender.draggingPasteboard.pasteboardItems?.count ?? 0)
        guard acceptsIncomingFileDrops, !(sender.draggingSource as AnyObject? === self) else {
            runtime.recordFileDrag("localDragRejected.inactiveOrSource"); return []
        }
        guard runtime.hasReceivedFrame else {
            runtime.recordFileDrag("localDragRejected.noFrame"); return []
        }
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              runtime.beginLocalDrag(urls) else {
            runtime.recordFileDrag("localDragRejected.fileURLsOrConnection"); return []
        }
        incomingDrag = true
        // A drag can enter through the letterbox before reaching the desktop.
        // Keep tracking it so draggingUpdated can accept it over the image.
        return updateDragPointer(sender) ? .copy : []
    }
    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard acceptsIncomingFileDrops, incomingDrag, updateDragPointer(sender) else { return [] }
        return .copy
    }
    @discardableResult private func updateDragPointer(_ sender: any NSDraggingInfo) -> Bool {
        guard let point = ScreenSharingGeometry.remotePoint(convert(sender.draggingLocation, from: nil), in: bounds, remoteSize: runtime.desktopSize) else { return false }
        runtime.sendPointer(x: Int(point.x), y: Int(point.y), buttons: 1)
        return true
    }
    public override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        if incomingDrag { runtime.cancelLocalDrag(); incomingDrag = false }
    }
    public override func draggingEnded(_ sender: any NSDraggingInfo) {
        if incomingDrag { runtime.cancelLocalDrag(); incomingDrag = false }
    }
    public override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        acceptsIncomingFileDrops && incomingDrag && runtime.hasReceivedFrame &&
        ScreenSharingGeometry.remotePoint(convert(sender.draggingLocation, from: nil), in: bounds, remoteSize: runtime.desktopSize) != nil
    }
    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard acceptsIncomingFileDrops, incomingDrag, runtime.hasReceivedFrame,
              let point = ScreenSharingGeometry.remotePoint(convert(sender.draggingLocation, from: nil), in: bounds, remoteSize: runtime.desktopSize) else {
            if incomingDrag { runtime.cancelLocalDrag(); incomingDrag = false }
            return false
        }
        runtime.sendPointer(x: Int(point.x), y: Int(point.y), buttons: 1)
        runtime.commitLocalDrag()
        // The remote drag was started by the pasteboard message. A balanced
        // release completes it at Finder's real hit-tested destination.
        runtime.sendPointer(x: Int(point.x), y: Int(point.y), buttons: 0)
        incomingDrag = false
        return true
    }
    private func beginRemoteFileDragIfReady() {
        guard !outgoingDrag, buttons & 1 != 0, let event = lastDragEvent,
              NSEvent.pressedMouseButtons & 1 != 0,
              ScreenSharingGeometry.remotePoint(convert(event.locationInWindow, from: nil), in: bounds, remoteSize: runtime.desktopSize) == nil,
              !runtime.remoteDragPaths.isEmpty else { return }
        let paths = runtime.remoteDragPaths
        guard paths.count <= 256 else { return }
        var names = Set<String>()
        let point = convert(event.locationInWindow, from: nil)
        let items = paths.enumerated().map { index, path -> NSDraggingItem in
            let original = (path as NSString).lastPathComponent
            var name = original; var suffix = 2
            while names.contains(name) {
                let stem = (original as NSString).deletingPathExtension
                let ext = (original as NSString).pathExtension
                name = "\(stem) \(suffix)" + (ext.isEmpty ? "" : ".\(ext)"); suffix += 1
            }
            names.insert(name)
            let promise = ScreenSharingFilePromise(path: path, name: name, runtime: runtime)
            let item = NSDraggingItem(pasteboardWriter: promise.provider())
            let icon = NSWorkspace.shared.icon(for: path.hasSuffix("/") ? .folder : .data)
            item.setDraggingFrame(NSRect(x: point.x + CGFloat(index % 5) * 4, y: point.y, width: 32, height: 32), contents: icon)
            return item
        }
        outgoingDrag = true
        runtime.recordFileDrag("remoteDragStarted", count: paths.count)
        // Cancel the remote Finder gesture before local AppKit takes over, so
        // releasing outside the canvas cannot move the source on the remote.
        runtime.sendKey(0xff1b, down: true); runtime.sendKey(0xff1b, down: false)
        releaseInput()
        let drag = beginDraggingSession(with: items, event: event, source: self)
        drag.animatesToStartingPositionsOnCancelOrFail = true
        lastDragEvent = nil
    }
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    public func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        outgoingDrag = false; runtime.remoteDragPaths = []; lastDragEvent = nil
        releaseInput()
    }

    private static let keysyms: [UInt16: UInt32] = [
        36: 0xff0d, 48: 0xff09, 51: 0xff08, 53: 0xff1b, 117: 0xffff,
        123: 0xff51, 124: 0xff53, 125: 0xff54, 126: 0xff52,
        115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56,
        122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1, 96: 0xffc2, 97: 0xffc3,
        98: 0xffc4, 100: 0xffc5, 101: 0xffc6, 109: 0xffc7, 103: 0xffc8, 111: 0xffc9,
    ]
    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex screenVertex(uint id [[vertex_id]]) {
        const float2 positions[] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
        const float2 uv[] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
        return {float4(positions[id],0,1),uv[id]};
    }
    fragment float4 screenFragment(Vertex v [[stage_in]], texture2d<float> y [[texture(0)]],
        texture2d<float> u [[texture(1)]], texture2d<float> vv [[texture(2)]], constant uint& biplanar [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        if (biplanar == 2) return float4(y.sample(s,v.uv).rgb, 1.0);
        float l = y.sample(s,v.uv).r;
        float2 chroma = biplanar ? u.sample(s,v.uv).rg : float2(u.sample(s,v.uv).r,vv.sample(s,v.uv).r);
        chroma -= float2(128.0/255.0);
        return float4(clamp(float3(l+1.5748*chroma.y,l-0.187324*chroma.x-0.468124*chroma.y,l+1.8556*chroma.x),0.0,1.0),1.0);
    }
    """
}
