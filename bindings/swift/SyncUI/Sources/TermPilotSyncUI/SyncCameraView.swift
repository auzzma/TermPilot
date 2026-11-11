import SwiftUI
@preconcurrency import AVFoundation

// Capture and permissions belong to the native UI. No frames leave the device.
private final class SyncCamera: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "TermPilot.Sync.Camera")
    var found: (@Sendable (String) -> Void)?
    var failed: (@Sendable (String) -> Void)?
    private var stopped = false
    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                guard allowed else { self.failed?("未获得相机权限，请在系统设置中允许相机访问，或返回粘贴配置码。"); return }
                do {
                    guard let device = AVCaptureDevice.default(for: .video) else { self.failed?("未检测到摄像头，请返回后使用粘贴配置码。"); return }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureMetadataOutput()
                    self.session.beginConfiguration()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else { self.session.commitConfiguration(); self.failed?("无法启动相机，请使用粘贴配置码。"); return }
                    self.session.addInput(input); self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main)
                    guard output.availableMetadataObjectTypes.contains(.qr) else { self.session.commitConfiguration(); self.failed?("此相机无法识别二维码，请使用粘贴配置码。"); return }
                    output.metadataObjectTypes = [.qr]
                    self.session.commitConfiguration(); self.session.startRunning()
                } catch { self.failed?("无法启动相机，请检查相机权限或使用粘贴配置码。") }
            }
        }
    }
    func stop() { queue.async { self.stopped = true; self.session.stopRunning() } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in objects {
            if let value = (object as? AVMetadataMachineReadableCodeObject)?.stringValue, value.hasPrefix("TP-SYNC:1:"), value.utf8.count <= 24000 {
                found?(value); stop(); return
            }
        }
    }
}
struct SyncCameraView: View {
    let found: @MainActor (String) -> Void
    @State private var camera = SyncCamera()
    @State private var error = ""
    @State private var accepted = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 16) {
            Text("将另一台设备上的配置二维码放入画面中。")
            SyncCameraPreview(session: camera.session).frame(minHeight: 260).clipShape(RoundedRectangle(cornerRadius: 16))
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
        }.padding()
        .onAppear { startCamera() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !accepted { camera = SyncCamera(); startCamera() }
            else { camera.stop() }
        }
        .onDisappear { camera.stop() }
    }
    private func startCamera() {
            camera.found = { value in Task { @MainActor in if !accepted { accepted = true; found(value) } } }
            camera.failed = { value in Task { @MainActor in error = value } }
            camera.start()
    }
}
#if os(macOS)
import AppKit
private final class CameraSurface: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.addSublayer(preview); preview.videoGravity = .resizeAspectFill }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); preview.frame = bounds }
}
private struct SyncCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> CameraSurface { let view = CameraSurface(frame: .zero); view.preview.session = session; return view }
    func updateNSView(_ view: CameraSurface, context: Context) { view.preview.session = session }
}
#else
import UIKit
private final class CameraSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
}
private struct SyncCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> CameraSurface { let view = CameraSurface(); let layer = view.layer as! AVCaptureVideoPreviewLayer; layer.session = session; layer.videoGravity = .resizeAspectFill; return view }
    func updateUIView(_ view: CameraSurface, context: Context) { (view.layer as? AVCaptureVideoPreviewLayer)?.session = session }
}
#endif
