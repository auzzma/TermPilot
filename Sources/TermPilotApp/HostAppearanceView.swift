import AppKit
import SwiftUI
import TermPilotDomain

struct HostIconView: View {
    let host: TermPilotDomain.Host
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: max(4, size * 0.24),
                style: .continuous
            )
            .fill(Color(hostHex: host.effectiveIconColorHex) ?? .accentColor)

            if host.iconMode == .custom {
                Image(systemName: (host.iconID ?? .server).systemImage)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.24)
            } else if let distro = host.effectiveDistro,
                      let image = distroImage(distro) {
                if distro == .h3c {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(size * 0.12)
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .padding(size * 0.24)
                }
            } else {
                Image(systemName: "server.rack")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .padding(size * 0.25)
            }
        }
        .frame(width: size, height: size)
    }

    private func distroImage(_ distro: HostDistroID) -> NSImage? {
        guard let url = AppResourceLocator.url(
            forResource: distro.rawValue,
            withExtension: "svg",
            subdirectory: "distro"
        ) ?? AppResourceLocator.url(
            forResource: distro.rawValue,
            withExtension: "svg"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

struct HostAppearanceEditor: View {
    @Binding var host: TermPilotDomain.Host

    var body: some View {
        VStack(spacing: 12) {
            HostIconView(host: host, size: 68)
                .frame(maxWidth: .infinity)
                .frame(height: 112)
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

            HStack(alignment: .top, spacing: 12) {
                appearanceField("Source") {
                    Picker("", selection: sourceModeBinding) {
                        Text(verbatim: localized("Auto Detect"))
                            .tag(HostDistroMode.auto)
                        Text(verbatim: localized("Manual"))
                            .tag(HostDistroMode.manual)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if sourceMode == .manual {
                    appearanceField("Icon") {
                        Picker("", selection: manualIconBinding) {
                            Section(localized("Brand")) {
                                ForEach(HostDistroID.allCases, id: \.self) {
                                    Text(verbatim: $0.appLocalizedTitle)
                                        .tag(HostManualIconSelection.brand($0))
                                }
                            }
                            Section(localized("Type")) {
                                ForEach(HostIconID.allCases, id: \.self) {
                                    Label(
                                        $0.appLocalizedTitle,
                                        systemImage: $0.systemImage
                                    )
                                    .tag(HostManualIconSelection.type($0))
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                } else {
                    appearanceValueField(
                        title: "Current Value",
                        value: host.distro?.appLocalizedTitle
                            ?? AppLocalization.string(
                                "Detect after first connection"
                            )
                    )
                }
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                appearanceField("Icon Color") {
                    Picker("", selection: colorModeBinding) {
                        Text(verbatim: localized("Automatic"))
                            .tag(HostIconColorMode.auto)
                        Text(verbatim: localized("Manual"))
                            .tag(HostIconColorMode.manual)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                if host.iconColorMode == .manual {
                    appearanceField("Color") {
                        Picker("", selection: manualColorBinding) {
                            ForEach(HostIconColorID.allCases, id: \.self) {
                                Text($0.appLocalizedTitle)
                                    .tag(HostManualColorSelection.preset($0))
                            }
                            Divider()
                            Text(verbatim: localized("Custom Color"))
                                .tag(HostManualColorSelection.custom)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                } else {
                    appearanceField("Current Color") {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(
                                    Color(
                                        hostHex: host.effectiveIconColorHex
                                    ) ?? .accentColor
                                )
                                .frame(width: 14, height: 14)
                            Text(verbatim: currentIconLabel)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }

            if host.iconColorMode == .manual,
               manualColorSelection == .custom {
                appearanceField("Custom Color") {
                    HStack(spacing: 8) {
                        ColorPicker(
                            "",
                            selection: customColorBinding,
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        TextField(
                            "#2563EB",
                            text: Binding(
                                get: { host.iconColorCustom ?? "" },
                                set: { host.iconColorCustom = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                    }
                }
            }
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var sourceMode: HostDistroMode {
        host.distroMode == .manual || host.iconMode == .custom
            ? .manual
            : .auto
    }

    private var sourceModeBinding: Binding<HostDistroMode> {
        Binding(
            get: { sourceMode },
            set: { mode in
                host.distroMode = mode
                if mode == .auto {
                    host.iconMode = .auto
                    host.iconID = nil
                } else if host.manualDistro == nil {
                    host.manualDistro = host.effectiveDistro ?? .linux
                }
            }
        )
    }

    private var manualIconSelection: HostManualIconSelection {
        if host.iconMode == .custom {
            return .type(host.iconID ?? .server)
        }
        return .brand(host.manualDistro ?? host.effectiveDistro ?? .linux)
    }

    private var manualIconBinding: Binding<HostManualIconSelection> {
        Binding(
            get: { manualIconSelection },
            set: { selection in
                host.distroMode = .manual
                switch selection {
                case let .brand(distro):
                    host.manualDistro = distro
                    host.iconMode = .auto
                    host.iconID = nil
                case let .type(icon):
                    host.iconMode = .custom
                    host.iconID = icon
                }
            }
        )
    }

    private var colorModeBinding: Binding<HostIconColorMode> {
        Binding(
            get: { host.iconColorMode },
            set: { mode in
                host.iconColorMode = mode
                if mode == .auto {
                    host.iconColor = nil
                    host.iconColorCustom = nil
                } else if host.iconColor == nil,
                          !HostAppearance.isValidCustomColor(
                            host.iconColorCustom
                          ) {
                    host.iconColor = .blue
                }
            }
        )
    }

    private var manualColorSelection: HostManualColorSelection {
        HostAppearance.isValidCustomColor(host.iconColorCustom)
            ? .custom
            : .preset(host.iconColor ?? .blue)
    }

    private var manualColorBinding: Binding<HostManualColorSelection> {
        Binding(
            get: { manualColorSelection },
            set: { selection in
                host.iconColorMode = .manual
                switch selection {
                case let .preset(color):
                    host.iconColor = color
                    host.iconColorCustom = nil
                case .custom:
                    host.iconColor = nil
                    if !HostAppearance.isValidCustomColor(
                        host.iconColorCustom
                    ) {
                        host.iconColorCustom = "#2563EB"
                    }
                }
            }
        )
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                Color(hostHex: host.iconColorCustom ?? "")
                    ?? Color(hostHex: "#2563EB")!
            },
            set: { color in
                host.iconColorCustom = color.hostHex
            }
        )
    }

    private var currentIconLabel: String {
        if host.iconMode == .custom {
            return (host.iconID ?? .server).appLocalizedTitle
        }
        return host.effectiveDistro?.appLocalizedTitle
            ?? AppLocalization.string("Unknown")
    }

    private func appearanceValueField(
        title: String,
        value: String
    ) -> some View {
        appearanceField(title) {
            Text(verbatim: value)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func appearanceField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: localized(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .frame(maxWidth: .infinity, minHeight: 30)
                .padding(.horizontal, 10)
                .background(
                    Color(nsColor: .textBackgroundColor).opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 1)
                }
        }
        .frame(maxWidth: .infinity)
    }

    private func localized(_ key: String) -> String {
        AppLocalization.string(key)
    }
}

private enum HostManualIconSelection: Hashable {
    case brand(HostDistroID)
    case type(HostIconID)
}

private enum HostManualColorSelection: Hashable {
    case preset(HostIconColorID)
    case custom
}

extension HostDistroID {
    var appLocalizedTitle: String {
        AppLocalization.string("Host Distro \(rawValue)")
    }
}

extension HostIconID {
    var appLocalizedTitle: String {
        AppLocalization.string("Host Icon \(rawValue)")
    }

    var systemImage: String {
        switch self {
        case .server: "server.rack"
        case .terminal: "terminal"
        case .database: "cylinder"
        case .cloud: "cloud"
        case .router: "router"
        case .shield: "shield"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .box: "shippingbox"
        case .globe: "globe"
        case .cpu: "cpu"
        case .hardDrive: "internaldrive"
        case .network: "network"
        case .wifi: "wifi"
        case .lock: "lock"
        case .key: "key"
        case .monitor: "display"
        case .container: "shippingbox.fill"
        case .activity: "waveform.path.ecg"
        case .zap: "bolt"
        case .serverCog: "server.rack"
        }
    }
}

extension HostIconColorID {
    var appLocalizedTitle: String {
        AppLocalization.string("Host Color \(rawValue)")
    }
}

private extension Color {
    init?(hostHex: String) {
        let value = hostHex.trimmingCharacters(
            in: CharacterSet(charactersIn: "#")
        )
        guard value.count == 6,
              let rgb = UInt64(value, radix: 16)
        else {
            return nil
        }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }

    var hostHex: String {
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else {
            return "#2563EB"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}
