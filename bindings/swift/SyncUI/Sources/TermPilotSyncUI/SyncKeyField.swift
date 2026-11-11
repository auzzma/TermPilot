import SwiftUI

/// Keep the label visible while the native bordered field shows where to type.
struct SyncKeyField: View {
    let title: LocalizedStringKey
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        #if os(macOS)
        HStack(spacing: 16) {
            Text(title).frame(width: 132, alignment: .leading)
            input.frame(minWidth: 180, maxWidth: .infinity)
        }
        .padding(.vertical, 4)
        #else
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline)
            input
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.vertical, 4)
        #endif
    }

    private var input: some View {
        SecureField(title, text: $text, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 32)
    }
}
