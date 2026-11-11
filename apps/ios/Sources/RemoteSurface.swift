import AVFAudio
import MetalKit
import SwiftUI

struct RemoteSurface: UIViewRepresentable {
  @EnvironmentObject var model: AppModel
  @ObservedObject var session: MobileSession
  func makeUIView(context: Context) -> RemoteCanvasContainer { RemoteCanvasContainer() }
  func updateUIView(_ container: RemoteCanvasContainer, context: Context) {
    let view = container.mount(session: session, model: model)
    view.consume()
    view.updateCursor()
    view.preferredFramesPerSecond =
      UserDefaults.standard.integer(forKey: "TermPilot.fps") == 30 ? 30 : 60
  }
  static func dismantleUIView(_ view: RemoteCanvasContainer, coordinator: ()) { view.unmount() }
}
@MainActor final class RemoteCanvasContainer: UIView {
  private var canvas: RemoteCanvas?
  func mount(session: MobileSession, model: AppModel) -> RemoteCanvas {
    // SwiftUI can reuse a representable after replacing its observed session.
    // Input and the visible pointer must always use the toolbar's current session.
    if let canvas, canvas.session === session { canvas.model = model; return canvas }
    unmount()
    let view = RemoteCanvas(session: session, model: model)
    view.frame = bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(view)
    canvas = view
    return view
  }
  func unmount() {
    canvas?.releaseInput()
    canvas?.isPaused = true
    canvas?.removeFromSuperview()
    canvas = nil
  }
}
@MainActor final class RemoteCanvas: MTKView, MTKViewDelegate, UIDropInteractionDelegate {
  let session: MobileSession
  weak var model: AppModel?
  private var pipeline: MTLRenderPipelineState?
  private var commands: MTLCommandQueue?
  private var tiles: [Int: (JSON, [MTLTexture])] = [:]
  private var zoom: CGFloat = 1
  private var offset = CGPoint.zero
  private var startOffset = CGPoint.zero
  private var lastPoint = CGPoint.zero
  let cursorView = RemoteCursorView()
  private var cursorPoint: CGPoint {
    get { session.remoteCursorPoint ?? CGPoint(x: session.desktopSize.width / 2, y: session.desktopSize.height / 2) }
    set { session.remoteCursorPoint = newValue }
  }
  private var touchStart = CGPoint.zero
  private var touchMoved = false
  private var button = 0
  private var dirty = false
  private var updated = false
  private var presented = 0
  private var started = Date()
  init(session: MobileSession, model: AppModel) {
    self.session = session
    self.model = model
    super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
    preferredFramesPerSecond = 30
    delegate = self
    clearColor = MTLClearColorMake(0.02, 0.025, 0.035, 1)
    colorPixelFormat = .bgra8Unorm
    isUserInteractionEnabled = true
    accessibilityIdentifier = "remote-desktop-surface"
    isAccessibilityElement = true
    isMultipleTouchEnabled = true
    clipsToBounds = true
    addSubview(cursorView)
    updateCursor()
    guard let device else { session.videoDiagnostics.videoError = "Metal unavailable"; return }
    session.videoDiagnostics.renderer = "Metal · \(device.name)"
    commands = device.makeCommandQueue()
    do {
      let lib = try device.makeLibrary(source: Self.shader, options: nil)
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = lib.makeFunction(name: "screenVertex")
      d.fragmentFunction = lib.makeFunction(name: "screenFragment")
      d.colorAttachments[0].pixelFormat = colorPixelFormat
      pipeline = try device.makeRenderPipelineState(descriptor: d)
    } catch { session.videoDiagnostics.videoError = "Metal pipeline initialization failed"; model.error = error.localizedDescription }
    addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch)))
    let pan = UIPanGestureRecognizer(target: self, action: #selector(pan))
    pan.minimumNumberOfTouches = 2
    addGestureRecognizer(pan)
    let right = UILongPressGestureRecognizer(target: self, action: #selector(rightClick))
    addGestureRecognizer(right)
    addInteraction(UIDropInteraction(delegate: self))
    addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover)))
    accessibilityLabel = "远程桌面，单指点击或拖动，双指平移，捏合缩放，长按右键"
  }
  required init(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  override func layoutSubviews() {
    super.layoutSubviews()
    updateCursor()
  }
  /// Uses the same viewport transform as video rendering and absolute pointer input.
  /// This UIKit overlay does not require a new video frame or increment rendered FPS.
  func updateCursor() {
    let remote = session.desktopSize
    guard remote.width > 0, remote.height > 0 else {
      cursorView.isHidden = true
      return
    }
    let p = clampedCursor(cursorPoint)
    if session.remoteCursorPoint != nil { cursorPoint = p }
    let rect = contentRect(size: bounds.size)
    let tip = CGPoint(x: rect.minX + floor(p.x) / remote.width * rect.width,
                      y: rect.minY + floor(p.y) / remote.height * rect.height)
    let visible = session.touchpad && !session.isClosing && session.localDragPaths.isEmpty
      && bounds.width > 0 && bounds.height > 0 && bounds.contains(tip)
    cursorView.place(tip: tip, visible: visible)
    accessibilityValue = session.touchpad ? "\(Int(p.x)), \(Int(p.y))" : nil
  }
  private func clampedCursor(_ point: CGPoint) -> CGPoint {
    CGPoint(x: min(max(0, session.desktopSize.width - 1), max(0, point.x)),
            y: min(max(0, session.desktopSize.height - 1), max(0, point.y)))
  }
  func setViewport(zoom: CGFloat, offset: CGPoint) {
    self.zoom = min(4, max(1, zoom))
    self.offset = offset
    dirty = true
    updateCursor()
  }
  func consume() {
    let packets = session.frames
    session.frames.removeAll()
    for (tile, packet) in packets {
      if let textures = makeTextures(packet) {
        tiles[tile] = (packet.header, textures); dirty = true; updated = true
      } else { session.videoDiagnostics.videoError = "Video texture upload failed" }
    }
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { dirty = true }
  func draw(in view: MTKView) {
    let elapsed = Date().timeIntervalSince(started)
    if elapsed >= 1 {
      session.renderedFPS = Double(presented) / elapsed
      presented = 0
      started = Date()
    }
    guard dirty, UIApplication.shared.applicationState == .active, let pipeline,
      let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
      let buffer = commands?.makeCommandBuffer(),
      let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
    else { return }
    dirty = false
    encoder.setRenderPipelineState(pipeline)
    let rect = contentRect(size: drawableSize)
    let desktop = session.desktopSize
    for i in tiles.keys.sorted() {
      let (h, textures) = tiles[i]!
      let top = CGFloat(i * h.number("height"))
      guard top < desktop.height else { continue }
      encoder.setViewport(
        MTLViewport(
          originX: rect.minX, originY: rect.minY + top / desktop.height * rect.height,
          width: CGFloat(h.number("width")) / desktop.width * rect.width,
          height: CGFloat(h.number("height")) / desktop.height * rect.height, znear: 0, zfar: 1))
      for (n, t) in textures.enumerated() { encoder.setFragmentTexture(t, index: n) }
      var mode: UInt32 =
        h.text("pixelFormat") == "bgrx" ? 2 : h["biplanar"] as? Bool == true ? 1 : 0
      encoder.setFragmentBytes(&mode, length: 4, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    encoder.endEncoding()
    buffer.present(drawable)
    buffer.commit()
    if updated {
      presented += 1
      session.videoDiagnostics.rendered(now: ProcessInfo.processInfo.systemUptime)
      updated = false
    }
  }
  private func contentRect(size: CGSize) -> CGRect {
    let remote = session.desktopSize
    let scale = min(size.width / remote.width, size.height / remote.height) * zoom
    let w = remote.width * scale
    let h = remote.height * scale
    return CGRect(
      x: (size.width - w) / 2 + offset.x * size.width / max(1, bounds.width),
      y: (size.height - h) / 2 + offset.y * size.height / max(1, bounds.height), width: w, height: h
    )
  }
  private func point(_ p: CGPoint) -> CGPoint? {
    let r = contentRect(size: bounds.size)
    guard r.width > 0, r.height > 0, r.contains(p) else { return nil }
    return CGPoint(
      x: min(
        session.desktopSize.width - 1, max(0, (p.x - r.minX) / r.width * session.desktopSize.width)),
      y: min(
        session.desktopSize.height - 1,
        max(0, (p.y - r.minY) / r.height * session.desktopSize.height)))
  }
  func move(_ p: CGPoint, _ buttons: Int) {
    guard let model, let point = point(p) else { return }
    lastPoint = p
    cursorPoint = point
    updateCursor()
    model.attempt {
      try await model.send(
        self.session.id,
        ["kind": "pointer", "x": Int(point.x), "y": Int(point.y), "buttons": buttons])
    }
  }
  override var canBecomeFirstResponder: Bool { true }
  func sendCursor(_ point: CGPoint, _ buttons: Int) {
    cursorPoint = clampedCursor(point)
    updateCursor()
    guard let model else { return }
    let p = cursorPoint
    model.attempt {
      try await model.send(
        self.session.id, ["kind": "pointer", "x": Int(p.x), "y": Int(p.y), "buttons": buttons])
    }
  }
  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard event?.allTouches?.count == 1, let p = touches.first?.location(in: self) else { return }
    // The workspace consumes the first tap while the software keyboard is open.
    if !session.keyboardVisible { becomeFirstResponder() }
    lastPoint = p
    touchStart = p
    touchMoved = false
    if session.touchpad && session.localDragPaths.isEmpty {
      button = session.dragLocked ? 1 : 0
      sendCursor(cursorPoint, button)
    } else {
      button = 1
      move(p, 1)
    }
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    guard let p = touches.first?.location(in: self) else { return }
    if abs(p.x - touchStart.x) + abs(p.y - touchStart.y) > 6 { touchMoved = true }
    if session.touchpad && session.localDragPaths.isEmpty {
      let scale = max(0.001, contentRect(size: bounds.size).width / session.desktopSize.width)
      sendCursor(
        CGPoint(
          x: cursorPoint.x + (p.x - lastPoint.x) / scale,
          y: cursorPoint.y + (p.y - lastPoint.y) / scale), session.dragLocked ? 1 : 0)
      lastPoint = p
    } else if button != 0 {
      move(p, button)
    }
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    if session.touchpad && session.localDragPaths.isEmpty {
      if !touchMoved && !session.dragLocked {
        sendCursor(cursorPoint, 1)
        sendCursor(cursorPoint, 0)
      }
    } else {
      move(touches.first?.location(in: self) ?? lastPoint, 0)
    }
    if !session.dragLocked { releaseInput() }
    if !session.localDragPaths.isEmpty, let model {
      session.localDragPaths = []
      model.attempt { try await model.send(self.session.id, ["kind": "dragDrop"]) }
    }
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { releaseInput() }
  @objc private func hover(_ g: UIHoverGestureRecognizer) { move(g.location(in: self), 0) }
  override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if !sendKeys(presses, true) { super.pressesBegan(presses, with: event) }
  }
  override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    if !sendKeys(presses, false) { super.pressesEnded(presses, with: event) }
  }
  override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
    releaseInput()
  }
  private func sendKeys(_ presses: Set<UIPress>, _ down: Bool) -> Bool {
    guard let model else { return false }
    var handled = false
    for press in presses {
      guard let key = press.key else { continue }
      let codes: [Int: Int] = [
        40: 0xff0d, 41: 0xff1b, 42: 0xff08, 43: 0xff09, 73: 0xff63, 74: 0xff50, 75: 0xff55,
        76: 0xffff, 77: 0xff57, 78: 0xff56, 79: 0xff53, 80: 0xff51, 81: 0xff54, 82: 0xff52,
        224: 0xffe3, 225: 0xffe1, 226: 0xffe9, 227: 0xffeb, 228: 0xffe4, 229: 0xffe2, 230: 0xffea,
        231: 0xffec,
      ]
      let raw = key.keyCode.rawValue
      let sym =
        codes[raw]
        ?? ((58...69).contains(raw)
          ? 0xffbe + raw - 58
          : key.charactersIgnoringModifiers.unicodeScalars.first.map {
            Int($0.value) > 255 ? Int($0.value) | 0x0100_0000 : Int($0.value)
          })
      if let sym {
        handled = true
        model.attempt {
          try await model.send(self.session.id, ["kind": "key", "key": sym, "down": down])
        }
      }
    }
    return handled
  }
  func dropInteraction(_ interaction: UIDropInteraction, canHandle drop: UIDropSession) -> Bool {
    (session.protocolKind == "rdp" || session.host.text("mode") == "highPerformance")
      && drop.items.contains { $0.itemProvider.hasItemConformingToTypeIdentifier("public.item") }
  }
  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate drop: UIDropSession)
    -> UIDropProposal
  { UIDropProposal(operation: .copy) }
  func dropInteraction(_ interaction: UIDropInteraction, performDrop drop: UIDropSession) {
    guard let model, let root = model.runtime?.directory,
      let target = point(drop.location(in: self))
    else { return }
    let providers = drop.items.map(\.itemProvider)
    model.attempt {
      var paths: [String] = []
      for provider in providers {
        paths.append(try await FileStager.receive(provider, root: root).path)
      }
      if self.session.protocolKind == "rdp" {
        try await model.send(
          self.session.id, ["kind": "clipboardOffer", "offerId": UUID().uuidString, "paths": paths])
        self.session.toolsReturnPanel = "terminal"
        self.session.selectedTool = "files"
        self.session.activePanel = "tools"
      } else {
        try await model.send(self.session.id, ["kind": "dragEnter", "paths": paths])
        try await model.send(
          self.session.id,
          ["kind": "pointer", "x": Int(target.x), "y": Int(target.y), "buttons": 1])
        try await model.send(
          self.session.id,
          ["kind": "pointer", "x": Int(target.x), "y": Int(target.y), "buttons": 0])
        try await model.send(self.session.id, ["kind": "dragDrop"])
      }
    }
  }
  func releaseInput() {
    button = 0
    guard let model else { return }
    model.attempt { try await model.send(self.session.id, ["kind": "release"]) }
  }
  @objc private func pinch(_ g: UIPinchGestureRecognizer) {
    releaseInput()
    setViewport(zoom: zoom * g.scale, offset: offset)
    g.scale = 1
  }
  @objc private func pan(_ g: UIPanGestureRecognizer) {
    releaseInput()
    if g.state == .began { startOffset = offset }
    let d = g.translation(in: self)
    setViewport(zoom: zoom, offset: CGPoint(x: startOffset.x + d.x, y: startOffset.y + d.y))
  }
  @objc private func rightClick(_ g: UILongPressGestureRecognizer) {
    if g.state == .began {
      touchMoved = true
      if session.touchpad { sendCursor(cursorPoint, 2) } else { move(g.location(in: self), 2) }
    }
    if g.state == .ended || g.state == .cancelled {
      if session.touchpad { sendCursor(cursorPoint, 0) } else { move(g.location(in: self), 0) }
    }
  }
  private func makeTextures(_ packet: MobilePacket) -> [MTLTexture]? {
    guard let device else { return nil }
    let h = packet.header
    let raw = h.text("pixelFormat") == "bgrx"
    let bi = h["biplanar"] as? Bool == true
    let widths =
      raw
      ? [h.number("width")] : [h.number("width"), h.number("chromaWidth"), h.number("chromaWidth")]
    let heights =
      raw
      ? [h.number("height")]
      : [h.number("height"), h.number("chromaHeight"), h.number("chromaHeight")]
    let strides =
      raw
      ? [h.number("yStride")] : [h.number("yStride"), h.number("uvStride"), h.number("uvStride")]
    let offsets = raw ? [0] : [0, h.number("yLength"), h.number("yLength") + h.number("uLength")]
    var textures: [MTLTexture] = []
    for i in 0..<(raw ? 1 : bi ? 2 : 3) {
      guard widths[i] > 0, heights[i] > 0, strides[i] > 0,
        offsets[i] + strides[i] * heights[i] <= packet.data.count
      else { return nil }
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: raw ? .bgra8Unorm : bi && i == 1 ? .rg8Unorm : .r8Unorm, width: widths[i],
        height: heights[i], mipmapped: false)
      d.storageMode = .shared
      guard let t = device.makeTexture(descriptor: d) else { return nil }
      packet.data.withUnsafeBytes {
        t.replace(
          region: MTLRegionMake2D(0, 0, widths[i], heights[i]), mipmapLevel: 0,
          withBytes: $0.baseAddress!.advanced(by: offsets[i]), bytesPerRow: strides[i])
      }
      textures.append(t)
    }
    while textures.count < 3 { textures.append(textures.last!) }
    return textures
  }
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
