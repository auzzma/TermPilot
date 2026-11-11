// Read-only two-window validation viewer. Receives decoded frames over stdin;
// no remote credentials, input handling, clipboard, audio playback or disk pixels.
// Texture layout and conversion follow ScreenSharingSurface's production renderer.
import AppKit
import MetalKit
import Foundation

struct ProbeFrame {
    let header: [String: Any]
    let data: Data
    func n(_ key: String) -> Int { (header[key] as? NSNumber)?.intValue ?? 0 }
}

final class ProbeView: MTKView, MTKViewDelegate {
    let host: String
    var generation = ""
    var desktop = CGSize(width: 1920, height: 1080)
    var tiles: [Int: (ProbeFrame, [MTLTexture])] = [:]
    var queue: MTLCommandQueue!
    var pipeline: MTLRenderPipelineState!
    var changed = false
    var presented = 0
    init(host: String) throws {
        self.host = host
        super.init(frame: NSRect(x: 0, y: 0, width: 660, height: 372), device: MTLCreateSystemDefaultDevice())
        guard let device else { throw NSError(domain: "Metal unavailable", code: 1) }
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1)
        preferredFramesPerSecond = 30
        queue = device.makeCommandQueue()
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "screenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "screenFragment")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        delegate = self
        setAccessibilityLabel("Read-only remote desktop " + host)
    }
    required init(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func accept(_ frame: ProbeFrame) {
        let id = frame.header["generation"] as? String ?? ""
        if generation != id { generation = id; tiles.removeAll() }
        desktop = CGSize(width: frame.n("desktopWidth"), height: frame.n("desktopHeight"))
        guard desktop.width > 0, desktop.height > 0, let textures = textures(frame) else { return }
        tiles[frame.n("tile")] = (frame, textures)
        changed = true
    }
    func textures(_ frame: ProbeFrame) -> [MTLTexture]? {
        guard let device else { return nil }
        let bi = frame.header["biplanar"] as? Bool == true
        let widths = [frame.n("width"),frame.n("chromaWidth"),frame.n("chromaWidth")]
        let heights = [frame.n("height"),frame.n("chromaHeight"),frame.n("chromaHeight")]
        let strides = [frame.n("yStride"),frame.n("uvStride"),frame.n("uvStride")]
        let offsets = [0,frame.n("yLength"),frame.n("yLength")+frame.n("uLength")]
        var textures: [MTLTexture] = []
        for index in 0..<(bi ? 2 : 3) {
            guard widths[index] > 0, heights[index] > 0, strides[index] > 0,
                  offsets[index] + strides[index] * heights[index] <= frame.data.count else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: index == 1 && bi ? .rg8Unorm : .r8Unorm,
                width: widths[index], height: heights[index], mipmapped: false)
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            frame.data.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0,0,widths[index],heights[index]), mipmapLevel: 0,
                    withBytes: bytes.baseAddress!.advanced(by: offsets[index]), bytesPerRow: strides[index])
            }
            textures.append(texture)
        }
        if textures.count == 2 { textures.append(textures[1]) }
        return textures
    }
    func draw(in view: MTKView) {
        guard !tiles.isEmpty, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        let scale = min(drawableSize.width / desktop.width, drawableSize.height / desktop.height)
        let width = desktop.width * scale, height = desktop.height * scale
        let x = (drawableSize.width-width)/2, y = (drawableSize.height-height)/2
        encoder.setRenderPipelineState(pipeline)
        for index in tiles.keys.sorted() {
            let (frame, textures) = tiles[index]!
            let top = index * frame.n("height")
            guard CGFloat(top) < desktop.height else { continue }
            encoder.setViewport(MTLViewport(originX: x, originY: y+CGFloat(top)*scale,
                width: CGFloat(frame.n("width"))*scale, height: CGFloat(frame.n("height"))*scale, znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: max(0,Int(x)), y: max(0,Int(y)), width: max(1,Int(width)), height: max(1,Int(height))))
            for (i, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: i) }
            var bi: UInt32 = frame.header["biplanar"] as? Bool == true ? 1 : 0
            encoder.setFragmentBytes(&bi, length: 4, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        if changed {
            changed = false
            buffer.addCompletedHandler { [weak self] command in
                guard command.status == .completed else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.presented += 1
                    self.window?.title = "TermPilot 验证 · \(self.host) · \(Int(self.desktop.width)) × \(Int(self.desktop.height)) · 已呈现 \(self.presented)"
                    let event: [String:Any] = ["host":self.host,"presented":self.presented,"generation":self.generation]
                    if let data = try? JSONSerialization.data(withJSONObject: event) {
                        FileHandle.standardOutput.write(data + Data([10]))
                    }
                }
            }
        }
        buffer.present(drawable)
        buffer.commit()
    }
    static let shader = """
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
        float l = y.sample(s,v.uv).r;
        float2 chroma = biplanar ? u.sample(s,v.uv).rg : float2(u.sample(s,v.uv).r,vv.sample(s,v.uv).r);
        chroma -= float2(128.0/255.0);
        return float4(clamp(float3(l+1.5748*chroma.y,l-0.187324*chroma.x-0.468124*chroma.y,l+1.8556*chroma.x),0.0,1.0),1.0);
    }
    """
}

var views: [String: ProbeView] = [:]
var windows: [NSWindow] = []
func show(_ frame: ProbeFrame) throws {
    guard let host = frame.header["host"] as? String else { return }
    if views[host] == nil {
        let view = try ProbeView(host: host)
        let bounds = NSScreen.main?.visibleFrame ?? NSRect(x: 0,y: 0,width: 1440,height: 900)
        let width = min(660.0,(bounds.width-60)/2), height = width*9/16
        let window = NSWindow(contentRect: NSRect(x: bounds.minX+20+CGFloat(windows.count)*(width+20),
            y: bounds.midY-height/2, width: width, height: height),
            styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.title = "TermPilot 验证 · " + host
        views[host] = view
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    views[host]?.accept(frame)
}
func exact(_ count: Int) -> Data? {
    var data = Data(count: count), offset = 0
    let ok = data.withUnsafeMutableBytes { bytes in
        while offset < count {
            let n = Darwin.read(STDIN_FILENO, bytes.baseAddress!.advanced(by: offset), count-offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
    return ok ? data : nil
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
DispatchQueue.global(qos: .userInitiated).async {
    while let prefix = exact(4) {
        let size = prefix.reduce(0) { ($0 << 8) | Int($1) }
        guard (2...65536).contains(size), let data = exact(size),
              let header = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any],
              let length = header["payloadLength"] as? Int, (0...67_108_864).contains(length),
              let payload = exact(length) else { break }
        DispatchQueue.main.sync { try? show(ProbeFrame(header: header, data: payload)) }
    }
    DispatchQueue.main.async { NSApp.terminate(nil) }
}
app.run()
