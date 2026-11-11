import AppKit
import SwiftUI
import XCTest
@testable import TermPilotApp

final class FileTransferActivityTests: XCTestCase {
    @MainActor
    func testSummaryTracksAllProtocolsAndIgnoresPausedAndStaleRates() {
        let model = FileTransferActivityModel()
        let now = Date()
        var upload = FileTransferRecord(kind: .upload, name: "upload", sourcePath: "", destinationPath: "",
            bytesPerSecond: 120, startedAt: now)
        var download = FileTransferRecord(kind: .download, name: "download", sourcePath: "", destinationPath: "",
            bytesPerSecond: 80, startedAt: now)
        download.protocolName = "RDP"
        var paused = upload
        paused.id = UUID(); paused.status = .paused; paused.protocolName = "Screen Sharing"
        var failed = upload
        failed.id = UUID(); failed.status = .failed("disconnected")
        model.records = [upload, download, paused, failed]
        XCTAssertEqual(model.unfinishedCount, 3)
        XCTAssertEqual(model.attentionCount, 1)
        XCTAssertEqual(model.bytesPerSecond(for: .upload, at: now), 120)
        XCTAssertEqual(model.bytesPerSecond(for: .download, at: now), 80)
        XCTAssertEqual(model.bytesPerSecond(for: .upload, at: now.addingTimeInterval(3)), 0)
        upload.bytesPerSecond = .infinity
        XCTAssertEqual(upload.currentBytesPerSecond(at: now), 0)
        XCTAssertTrue(failed.belongs(to: .attention))
        XCTAssertTrue(failed.belongs(to: .completed))
        XCTAssertEqual(failed.statusMessage, "disconnected")
    }

    @MainActor
    func testRemoteDetailsSurviveUnifiedPresentation() {
        XCTAssertEqual(AppState.remoteTransferDetail(stage: "waitingDestination", direction: "upload", isRDP: false),
                       AppLocalization.string("Waiting for Remote Destination"))
        XCTAssertEqual(AppState.remoteTransferDetail(stage: "confirming", direction: "upload", isRDP: false),
                       AppLocalization.string("Confirming Remote Copy"))
        XCTAssertNil(AppState.remoteTransferDetail(stage: "completed", direction: "download", isRDP: true))
        XCTAssertEqual(AppState.remoteTransferError("sourceChanged", isRDP: false),
                       AppLocalization.string("The source file changed during transfer."))
        XCTAssertEqual(AppState.remoteTransferError("RDP detail", isRDP: true), "RDP detail")
    }

    @MainActor
    func testPanelContrastIsIndependentOfRemoteDesktopAndWindowFocus() throws {
        let state = AppState()
        var rdp = FileTransferRecord(kind: .upload, name: "Clipboard files", sourcePath: "", destinationPath: "",
            bytesTransferred: 141_000_000, totalBytes: 364_800_000, status: .paused)
        rdp.protocolName = "RDP"
        var apple = FileTransferRecord(kind: .upload, name: "TermPilot-中文.zip", sourcePath: "", destinationPath: "",
            bytesTransferred: 161_300_000, totalBytes: 364_800_000, bytesPerSecond: 9.51 * 1_048_576)
        apple.protocolName = "屏幕共享"
        state.recordFileTransfer(rdp); state.recordFileTransfer(apple)
        for scheme in [ColorScheme.light, .dark] {
            var reference: NSColor?
            for active in [true, false] {
                for lightDesktop in [true, false] {
                    let view = NSHostingView(rootView: TransferCenterView()
                        .frame(width: 560, height: 430)
                        .background(lightDesktop ? Color.white : Color.black)
                        .environmentObject(state).environment(\.colorScheme, scheme)
                        .environment(\.controlActiveState, active ? .active : .inactive)
                        .environment(\.locale, Locale(identifier: "zh-Hans")))
                    view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    view.frame = NSRect(x: 0, y: 0, width: 560, height: 430)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    // Inside the panel's left padding, away from text and the border.
                    let sample = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 3 / 560, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                    if let reference {
                        XCTAssertEqual(sample.redComponent, reference.redComponent, accuracy: 0.01)
                        XCTAssertEqual(sample.greenComponent, reference.greenComponent, accuracy: 0.01)
                        XCTAssertEqual(sample.blueComponent, reference.blueComponent, accuracy: 0.01)
                    } else { reference = sample }
                    if let directory = ProcessInfo.processInfo.environment["TERMPILOT_TRANSFER_SNAPSHOTS"] {
                        let name = "contrast-\(scheme)-\(lightDesktop ? "white" : "black")-\(active ? "active" : "inactive").png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                }
            }
        }
    }

    @MainActor
    func testControlsTargetTaskAndClearingPreservesPausedWork() throws {
        let state = AppState()
        let first = FileTransferRecord(kind: .upload, name: "中文.bin", sourcePath: "", destinationPath: "", totalBytes: 1000)
        let paused = FileTransferRecord(kind: .download, name: "folder", sourcePath: "", destinationPath: "", status: .paused)
        state.recordFileTransfer(first); state.recordFileTransfer(paused)
        var calls = [String]()
        state.fileTransferControls[first.id] = { action, item in
            XCTAssertEqual(item.id, first.id)
            if case .pause = action { calls.append("pause") }
        }
        state.controlFileTransfer(first.id, action: .pause)
        XCTAssertEqual(calls, ["pause"])
        state.finishFileTransfer(id: first.id, status: .succeeded, bytesTransferred: 1000)
        state.clearFinishedFileTransfers()
        XCTAssertEqual(state.fileTransfers.map(\.id), [paused.id])
        XCTAssertNil(state.fileTransferControls[first.id])
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: TransferCenterView().environmentObject(state).environment(\.colorScheme, scheme))
            view.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(view.fittingSize.width, 560)
            if let directory = ProcessInfo.processInfo.environment["TERMPILOT_TRANSFER_SNAPSHOTS"],
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("transfer-\(scheme).png"))
            }
        }
    }
    @MainActor
    func testPanelFitsBothLanguagesAndEmptyOrMixedTransfers() throws {
        for language in ["zh-Hans", "en"] {
            for scheme in [ColorScheme.light, .dark] {
                for empty in [true, false] {
                    let state = AppState()
                    if !empty {
                        var paused = FileTransferRecord(kind: .download, name: "Clipboard files.zip", connectionName: "Office PC",
                            sourcePath: "", destinationPath: "", bytesTransferred: 42_000_000, totalBytes: 120_000_000, status: .paused)
                        paused.protocolName = "RDP"
                        var preparing = FileTransferRecord(kind: .upload, name: "设计资源", connectionName: "Studio Mac",
                            sourcePath: "", destinationPath: "")
                        preparing.protocolName = "Screen Sharing"
                        preparing.detailMessage = language == "zh-Hans" ? "正在准备文件" : "Preparing Files"
                        state.recordFileTransfer(paused)
                        state.recordFileTransfer(preparing)
                        state.recordFileTransfer(FileTransferRecord(kind: .upload,
                            name: "26年力源CR2032报告210mAh_最终版本_包含多语言附件和测试结果.rar", connectionName: "Production Server",
                            sourcePath: "/Downloads/report.rar", destinationPath: "/srv/uploads/report.rar",
                            bytesTransferred: 38_100_000, totalBytes: 87_800_000, bytesPerSecond: 58.57 * 1_048_576))
                    }
                    let view = NSHostingView(rootView: TransferCenterView().environmentObject(state)
                        .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: language)))
                    view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(view.fittingSize.width, 560, accuracy: 1)
                    XCTAssertLessThanOrEqual(view.fittingSize.height, 640)
                    XCTAssertGreaterThan(view.fittingSize.height, 280)
                    if let directory = ProcessInfo.processInfo.environment["TERMPILOT_TRANSFER_SNAPSHOTS"] {
                        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("center-\(language)-\(scheme)-\(empty ? "empty" : "mixed").png"))
                    }
                }
            }
        }
    }

    @MainActor
    func testTransferPanelStaysInsideResizedWindow() async throws {
        let state = AppState()
        for index in 0..<8 {
            state.recordFileTransfer(FileTransferRecord(kind: .upload, name: "传输任务-\(index).zip",
                sourcePath: "", destinationPath: "", bytesTransferred: 40, totalBytes: 100))
        }
        let host = NSHostingView(rootView: Color.gray.overlay {
            FileTransferPanelOverlay(isPresented: .constant(true))
        }.environmentObject(state).environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for (size, empty) in [(CGSize(width: 1000, height: 700), false),
                              (CGSize(width: 900, height: 500), false),
                              (CGSize(width: 480, height: 360), false),
                              (CGSize(width: 1000, height: 700), false),
                              (CGSize(width: 900, height: 500), true)] {
            if empty { state.transferActivity.records = [] }
            window.setContentSize(size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(host.bounds.width, size.width, accuracy: 1)
            XCTAssertEqual(host.bounds.height, size.height, accuracy: 1)
            XCTAssertTrue(window.childWindows?.isEmpty ?? true, "Transfers must not create a separate popover window")
            let maximumSize = CGSize(width: size.width - 24, height: size.height - 24)
            let panel = NSHostingView(rootView: TransferCenterView(maximumSize: maximumSize, onClose: {})
                .environmentObject(state).environment(\.locale, Locale(identifier: "zh-Hans")))
            panel.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(panel.fittingSize.width, min(560, maximumSize.width))
            XCTAssertLessThanOrEqual(panel.fittingSize.height, maximumSize.height)
            if let directory = ProcessInfo.processInfo.environment["TERMPILOT_TRANSFER_SNAPSHOTS"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: directory)
                        .appendingPathComponent("in-window-\(Int(size.width))-\(Int(size.height))-\(empty ? "empty" : "active").png"))
            }
        }
    }

}
