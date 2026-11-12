import AppKit
import Foundation
import SwiftUI

struct TermPilotApplicationInfo: Equatable {
    var version: String
    var build: String
    var copyright: String

    static func current(bundle: Bundle = .main) -> Self {
        Self(
            version: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1.5",
            build: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "1",
            copyright: bundle.object(
                forInfoDictionaryKey: "NSHumanReadableCopyright"
            ) as? String ?? "TermPilot contributors."
        )
    }

    var localizedVersion: String {
        String(
            format: AppLocalization.string("Version %@ (%@)"),
            version,
            build
        )
    }
}

struct AboutSettingsView: View {
    private let applicationInfo = TermPilotApplicationInfo.current()
    @State private var showsLicense = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 96, height: 96)
                        .shadow(
                            color: .black.opacity(0.22),
                            radius: 14,
                            y: 8
                        )
                        .padding(.bottom, 22)

                    Text("TermPilot")
                        .font(.system(size: 28, weight: .semibold))

                    Text(verbatim: applicationInfo.localizedVersion)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.top, 12)

                    Text(verbatim: applicationInfo.copyright)
                        .font(.body)
                        .padding(.top, 18)

                    VStack(spacing: 8) {
                        Text("Open-source license")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(GPLLicense.title) { showsLicense = true }
                            .accessibilityIdentifier("open-gpl-license")
                    }
                    .padding(.top, 20)
                }
                .frame(maxWidth: .infinity)
                .frame(
                    minHeight: proxy.size.height,
                    alignment: .center
                )
                .padding(32)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("About TermPilot")
        .sheet(isPresented: $showsLicense) { GPLLicenseView() }
    }
}

enum GPLLicense {
    static let title = "GNU General Public License v3.0"
    static let text: String = {
        guard let url = AppResourceLocator.url(forResource: "GPL-3.0", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return AppLocalization.string("Unable to load the license text.")
        }
        return text
    }()
}

private struct GPLLicenseView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: GPLLicense.title).font(.headline)
            Divider()
            ScrollView {
                Text(verbatim: GPLLicense.text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("gpl-license-text")
                    .padding(.trailing, 8)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("close-gpl-license")
            }
        }
        .padding(24)
        .frame(width: 680, height: 520)
        .onExitCommand { dismiss() }
    }
}
