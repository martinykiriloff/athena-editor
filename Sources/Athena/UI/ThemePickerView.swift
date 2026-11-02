// ThemePickerView.swift
// Visual theme picker: one card per theme showing a live code preview.
// Swift 6, strict concurrency.

import SwiftUI
@preconcurrency import AppKit

// MARK: - ThemePickerView

struct ThemePickerView: View {
    @Environment(AppState.self) private var appState

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(appState.allThemes, id: \.id) { theme in
                ThemeCard(theme: theme, isSelected: theme == appState.currentTheme) {
                    appState.currentTheme = theme
                    appState.persistSetting(theme.id, for: "theme")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ThemeCard

private struct ThemeCard: View {
    let theme: EditorTheme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                preview
                HStack(spacing: 4) {
                    Text(theme.name).font(.callout)
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A few lines of pseudo-code in the theme's own colours.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 3) {
            line([("func ", theme.keyword), ("load", theme.function), ("() {", theme.foreground)])
            line([("  let ", theme.keyword), ("n", theme.foreground), (" = ", theme.foreground), ("42", theme.number)])
            line([("  // ", theme.comment), ("done", theme.comment)])
            line([("  return ", theme.keyword), ("\"ok\"", theme.string)])
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: theme.background), in: RoundedRectangle(cornerRadius: 6))
    }

    private func line(_ parts: [(String, NSColor)]) -> Text {
        var out = AttributedString()
        for (text, color) in parts {
            var run = AttributedString(text)
            run.foregroundColor = color
            out.append(run)
        }
        return Text(out)
    }
}
