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
    }
}
