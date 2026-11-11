import AppKit
import SwiftUI
import TermPilotDomain
import TermPilotScreenSharing

#if DEBUG
// In-process SwiftUI tests cannot inspect virtual accessibility children.
// Expose layout bounds only in test builds so native clicks follow the control.
struct ScreenSharingLoginButtonBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}
#endif

enum ScreenSharingEngineLocator {
    static func launch() -> ScreenSharingEngineLaunch {
        let root = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/missing-TermPilot-resources")
        return ScreenSharingEngineLaunch(
            executable: root.appendingPathComponent("engine/termpilot-engine"),
            lockDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("com.termpilot.screen-sharing")
        )
    }
}

struct ScreenSharingPane: View {
    static let statusBarHeight: CGFloat = 24
    @EnvironmentObject private var state: AppState
    @ObservedObject var runtime: ScreenSharingSessionRuntime
    let workspaceID: UUID
    let isActive: Bool
    @AppStorage("screenSharingClipboardSyncEnabled") private var clipboardSyncEnabled = true
    @AppStorage(RemoteDesktopPreferences.frameRateKey)
    private var remoteDesktopFrameRate = RemoteDesktopPreferences.defaultFrameRate
    @State private var showingVideoDiagnostics = false

    private var displayModeTitle: String {
        if runtime.isStandardVNC || runtime.isRDP {
            let route = runtime.descriptor.proxyProfileID != nil || runtime.descriptor.customProxyConfigured == true
                ? AppLocalization.string("Via Proxy") : AppLocalization.string("System Network")
            return "\(runtime.isRDP ? "RDP" : "VNC") · \(Int(runtime.desktopSize.width)) × \(Int(runtime.desktopSize.height)) · \(route)"
        }
        return String(format: AppLocalization.string("High Performance · %d × %d · SDR"),
                      Int(runtime.desktopSize.width), Int(runtime.desktopSize.height))
    }
    private var visible: Bool { isActive && state.activeWorkspaceID == workspaceID }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(runtime.descriptor.title, systemImage: "display.2").lineLimit(1)
                Spacer()
                if runtime.isActive {
                    if !runtime.isStandardVNC && !runtime.isRDP {
                        Button(AppLocalization.string("Enter Credential Password and Log In")) {
                            Task { await state.enterScreenSharingLoginPassword(sessionID: runtime.descriptor.id) }
                        }
                        .disabled(!visible || !runtime.canSendLoginPassword || runtime.isEnteringLoginPassword)
                        .accessibilityIdentifier("screen-sharing-login-password")
                        .help(AppLocalization.string("First click the empty password field for the matching remote account, then click this button. Sends the credential password and Return. Press Escape to cancel."))
                        #if DEBUG
                        .anchorPreference(key: ScreenSharingLoginButtonBounds.self, value: .bounds) { $0 }
                        #endif
                        if runtime.isEnteringLoginPassword {
                            Button("Cancel") { runtime.releaseInput() }
                                .keyboardShortcut(.cancelAction)
                                .accessibilityIdentifier("screen-sharing-login-password-cancel")
                        }
                    }
                    if !runtime.isRDP { Button { runtime.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh Screen") }
                    Toggle(isOn: $clipboardSyncEnabled) {
                        Image(systemName: "doc.on.clipboard")
                    }
                    .toggleStyle(.button)
                    .accessibilityLabel(AppLocalization.string("Automatic Bidirectional Clipboard Sync"))
                    .help(AppLocalization.string(clipboardSyncEnabled
                        ? (runtime.isRDP ? "RDP：双向同步文本和文件。文件接收完成后可在 Finder 中粘贴。" : "Clipboard sync is on. Click to turn off. Text only, up to 512 KB.")
                        : "Clipboard sync is off. Click to turn on."))
                    if !runtime.isStandardVNC {
                    Toggle(isOn: Binding(get: { runtime.audioEnabled }, set: { runtime.setAudioEnabled($0) })) {
                        Image(systemName: runtime.audioEnabled ? "speaker.wave.2" : "speaker.slash")
                    }.toggleStyle(.button).help("Play Remote Audio")
                    }
                    Button("Disconnect") { state.disconnectScreenSharing(sessionID: runtime.descriptor.id) }
                    if runtime.isRDP {
                        Menu {
                            Button("Ctrl + Alt + Delete") { runtime.sendSecureAttention() }
                            Button("全屏") { NSApp.keyWindow?.toggleFullScreen(nil) }
                            Divider()
                            ForEach(["1280 × 720", "1920 × 1080", "2560 × 1440", "3840 × 2160"], id: \.self) { size in
                                Button(size) {
                                    let parts = size.components(separatedBy: " × ")
                                    runtime.resizeRDP(width: Int(parts[0])!, height: Int(parts[1])!)
                                }
                            }
                        } label: { Image(systemName: "display") }
                    }
                }
                if !runtime.isStandardVNC && !runtime.isRDP {
                    Menu {
                        ForEach(HighPerformanceResolution.allCases, id: \.self) { resolution in
                            Button {
                                state.resizeHighPerformance(sessionID: runtime.descriptor.id, resolution: resolution)
                            } label: {
                                if runtime.highPerformanceResolution == resolution {
                                    Label(resolution.title, systemImage: "checkmark")
                                } else { Text(resolution.title) }
                            }
                        }
                        Divider()
                        Text(AppLocalization.string("Changing resolution reconnects the session."))
                    } label: { Image(systemName: "display") }
                    .help(AppLocalization.string("Remote resolution (reconnects)"))
                    .accessibilityIdentifier("high-performance-resolution")
                }
                Button {
                    Task { await state.close(sessionID: runtime.descriptor.id, in: workspaceID) }
                } label: { Image(systemName: "xmark") }.help("Close Session")
            }
            .font(.caption).buttonStyle(.borderless).padding(.horizontal, 12).frame(height: 36)
            Divider()
            ZStack {
                Color.black
                if runtime.isActive {
                    ScreenSharingSurface(runtime: runtime, isActive: visible) {
                        state.focus(sessionID: runtime.descriptor.id, workspaceID: workspaceID)
                    }
                    if !runtime.hasReceivedFrame {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text(AppLocalization.string(runtime.status.isEmpty ? "Waiting for Remote Video" : runtime.status))
                                .foregroundStyle(.white)
                        }.allowsHitTesting(false)
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "display.2").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text(runtime.isRDP ? "RDP" : AppLocalization.string("Screen Sharing")).font(.title2)
                        Text(verbatim: runtime.descriptor.hostname ?? "")
                            .foregroundStyle(.secondary)
                        if case let .failed(message) = runtime.lifecycle {
                            Text(AppLocalization.string(message)).font(.callout).foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                            if !runtime.connectionDiagnostics.isEmpty {
                                Text(runtime.connectionDiagnostics).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Button("Reconnect") { state.reconnect(sessionID: runtime.descriptor.id) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("screen-sharing-reconnect")
                        Text(verbatim: displayModeTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(24).frame(maxWidth: 500)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(verbatim: displayModeTitle).lineLimit(1)
                if !runtime.loginPasswordStatus.isEmpty {
                    Text(AppLocalization.string(runtime.loginPasswordStatus)).lineLimit(1)
                        .help(AppLocalization.string(runtime.loginPasswordStatus))
                        .accessibilityIdentifier("screen-sharing-login-password-status")
                }
                if runtime.isRDP && !runtime.status.isEmpty {
                    Text(verbatim: runtime.status).lineLimit(1).help(runtime.status)
                }
                Spacer(minLength: 8)
                Button { showingVideoDiagnostics = true } label: {
                    HStack(spacing: 10) {
                        Text("\(runtime.performance.framesPerSecond.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—") FPS")
                        Text("↓ \(bandwidth(runtime.performance.receiveBytesPerSecond))")
                        Text("↑ \(bandwidth(runtime.performance.sendBytesPerSecond))")
                        Image(systemName: "info.circle")
                    }
                    .monospacedDigit().fixedSize()
                }.buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("画面诊断"))
                .accessibilityIdentifier("remote-video-stats")
                .help(AppLocalization.string("画面诊断"))
            }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: Self.statusBarHeight)
        }
        .sheet(isPresented: $showingVideoDiagnostics) {
            VStack(alignment: .leading, spacing: 16) {
                Text(AppLocalization.string("画面诊断")).font(.headline)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let report = runtime.videoDiagnosticsReport(localize: AppLocalization.string)
                    ScrollView {
                        Text(verbatim: report).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("remote-video-report")
                    }
                    HStack {
                        Button(AppLocalization.string("Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }
                        Spacer()
                        Button(AppLocalization.string("Done")) { showingVideoDiagnostics = false }
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("remote-video-done")
                    }.padding(.top, 12)
                }
            }.padding(20).frame(minWidth: 420, idealWidth: 600, maxWidth: 680,
                                minHeight: 320, idealHeight: 520, maxHeight: 680)
        }
        .onAppear {
            runtime.setFrameRate(remoteDesktopFrameRate)
            runtime.setClipboardSyncEnabled(clipboardSyncEnabled)
            runtime.setVisible(visible)
        }
        .onChange(of: clipboardSyncEnabled) { _, value in runtime.setClipboardSyncEnabled(value) }
        .onChange(of: remoteDesktopFrameRate) { _, value in runtime.setFrameRate(value) }
        .onChange(of: visible) { _, value in runtime.setVisible(value) }
        .onDisappear { runtime.setVisible(false) }
        .alert(item: $runtime.certificatePrompt) { prompt in
            Alert(title: Text("验证 RDP 服务器证书"),
                  message: Text("服务器：\(prompt.endpoint)\n\(prompt.message)\nSHA-256：\(prompt.fingerprint)\n仅在确认是目标电脑后继续。本次信任仅用于当前会话。"),
                  primaryButton: .default(Text("本次继续")) { runtime.certificatePrompt = prompt; runtime.answerCertificate(true) },
                  secondaryButton: .cancel(Text("取消连接")) { runtime.certificatePrompt = prompt; runtime.answerCertificate(false) })
        }
    }
    private func bandwidth(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "— Mbps" }
        return "\((bytesPerSecond / 125_000).formatted(.number.precision(.fractionLength(2)))) Mbps"
    }
}
