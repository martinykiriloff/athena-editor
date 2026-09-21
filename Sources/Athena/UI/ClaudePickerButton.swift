// ClaudePickerButton.swift — Pill trigger + popover option list used in the
// Claude panel's session bar in place of stock NSMenu dropdowns.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - ClaudePickerOption

struct ClaudePickerOption<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let detail: String
    let icon: String
    var tint: Color = .accentColor
}

// MARK: - ClaudePickerButton

struct ClaudePickerButton<ID: Hashable>: View {
    @Environment(AppState.self) private var appState

    let label: String
    var icon: String? = nil
    var labelTint: Color = .secondary
    let header: String
    let options: [ClaudePickerOption<ID>]
    let selection: ID
    let help: String
    let onSelect: (ID) -> Void

    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: appState.sf(4)) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: appState.sf(9), weight: .medium))
                }
                Text(label)
                    .font(.system(size: appState.sf(10), weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: appState.sf(7), weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(labelTint)
            .padding(.horizontal, appState.sf(7))
            .padding(.vertical, appState.sf(3))
            .background(
                Capsule().fill(Color.primary.opacity(isPresented ? 0.1 : (isHovered ? 0.06 : 0)))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(help)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ClaudePickerList(header: header, options: options, selection: selection) { id in
                isPresented = false
                onSelect(id)
            }
            .environment(appState)
        }
    }
}

// MARK: - ClaudePickerList

private struct ClaudePickerList<ID: Hashable>: View {
    @Environment(AppState.self) private var appState

    let header: String
    let options: [ClaudePickerOption<ID>]
    let selection: ID
    let onSelect: (ID) -> Void

    @State private var hovered: ID?

    var body: some View {
        VStack(alignment: .leading, spacing: appState.sf(2)) {
            Text(header.uppercased())
                .font(.system(size: appState.sf(9), weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, appState.sf(8))
                .padding(.vertical, appState.sf(3))

            ForEach(options) { option in
                row(option)
            }
        }
        .padding(appState.sf(6))
        .frame(width: appState.sf(260))
    }

    private func row(_ option: ClaudePickerOption<ID>) -> some View {
        let isSelected = option.id == selection
        let shape = RoundedRectangle(cornerRadius: appState.sf(7), style: .continuous)

        return Button {
            onSelect(option.id)
        } label: {
            HStack(spacing: appState.sf(10)) {
                Image(systemName: option.icon)
                    .font(.system(size: appState.sf(11), weight: .medium))
                    .foregroundStyle(option.tint)
                    .frame(width: appState.sf(26), height: appState.sf(26))
                    .background(
                        RoundedRectangle(cornerRadius: appState.sf(6), style: .continuous)
                            .fill(option.tint.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: appState.sf(1)) {
                    Text(option.title)
                        .font(.system(size: appState.sf(11.5), weight: .medium))
                        .foregroundStyle(.primary)
                    Text(option.detail)
                        .font(.system(size: appState.sf(10)))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: appState.sf(4))

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: appState.sf(10), weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, appState.sf(8))
            .padding(.vertical, appState.sf(6))
            .background(shape.fill(rowFill(isSelected: isSelected, isHovered: hovered == option.id)))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = option.id } else if hovered == option.id { hovered = nil }
        }
    }

    private func rowFill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(isHovered ? 0.16 : 0.1) }
        return isHovered ? Color.primary.opacity(0.06) : .clear
    }
}
