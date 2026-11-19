import SwiftUI
import TermPilotTerminal

struct PasswordPromptAssistOverlay: View {
    let request: PasswordPromptRequest
    @ObservedObject var runtime: TerminalSessionRuntime

    let caret: CGRect

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.panelFrame(caret: caret, area: geometry.size, count: request.items.count)
            panel
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
        }
    }

    static func panelFrame(caret: CGRect, area: CGSize, count: Int) -> CGRect {
        let margin: CGFloat = 8
        let gap: CGFloat = 6
        let width = min(340, max(0, area.width - 2 * margin))
        let listHeight = min(190, 10 + CGFloat(count) * 36 + CGFloat(max(0, count - 1)) * 2)
        let preferredHeight = 66 + listHeight
        let below = max(0, area.height - margin - caret.maxY - gap)
        let above = max(0, caret.minY - gap - margin)
        let showBelow = below >= preferredHeight || below >= above
        let height = min(preferredHeight, showBelow ? below : above)
        let x = max(margin, min(caret.minX, area.width - margin - width))
        let y = showBelow ? caret.maxY + gap : caret.minY - gap - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.yellow)
                Text("Saved Passwords")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button {
                    runtime.dismissPasswordPromptAssist()
                    runtime.focus()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 10)
            .frame(height: 34)

            Divider()

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(request.items.enumerated()), id: \.element.id) {
                        index,
                        item in
                        credentialRow(
                            item,
                            isSelected: index == request.selectedIndex
                        )
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 190)

            Divider()

            Text(
                LocalizedStringKey(
                    request.presentation == .picker
                        ? "Use arrow keys to select, then press Enter."
                        : "Press Enter to paste the saved password."
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
        }
        .clipped()
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    private func credentialRow(
        _ item: PasswordPromptCredentialItem,
        isSelected: Bool
    ) -> some View {
        Button {
            runtime.selectPasswordPromptCredential(id: item.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key")
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let username = item.username, !username.isEmpty {
                        Text(username)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("••••••••")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.2) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
