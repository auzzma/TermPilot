import AppKit
import SwiftUI

struct RevealablePasswordField: View {
    @Binding private var text: String
    private let placeholder: String
    private let textAlignment: TextAlignment

    @State private var isRevealed = false
    @FocusState private var isFocused: Bool

    init(
        _ placeholder: String = "",
        text: Binding<String>,
        textAlignment: TextAlignment = .leading
    ) {
        _text = text
        self.placeholder = placeholder
        self.textAlignment = textAlignment
    }

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if isRevealed {
                    TextField(
                        "",
                        text: $text,
                        prompt: Text(verbatim: placeholder)
                    )
                } else {
                    SecureField(
                        "",
                        text: $text,
                        prompt: Text(verbatim: placeholder)
                    )
                }
            }
            .textContentType(.password)
            .textFieldStyle(.plain)
            .multilineTextAlignment(textAlignment)
            .focused($isFocused)

            Button {
                isRevealed.toggle()
                isFocused = true
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(
                AppLocalization.string(
                    isRevealed ? "Hide Password" : "Show Password"
                )
            )
            .help(
                AppLocalization.string(
                    isRevealed ? "Hide Password" : "Show Password"
                )
            )

            Button(action: copyPassword) {
                Image(systemName: "doc.on.doc")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(text.isEmpty)
            .accessibilityLabel(AppLocalization.string("Copy Password"))
            .help(AppLocalization.string("Copy Password"))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(minHeight: 30)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(
                    isFocused
                        ? Color.accentColor
                        : Color.secondary.opacity(0.25),
                    lineWidth: isFocused ? 2 : 1
                )
        }
    }

    private func copyPassword() {
        guard !text.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
