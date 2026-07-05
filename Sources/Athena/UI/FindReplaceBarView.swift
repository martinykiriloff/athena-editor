// FindReplaceBarView.swift
// Athena — floating find/replace bar overlaid on the active editor, backed by
// FindReplaceController (direct NSTextStorage find/replace, not NSTextFinder).
// Swift 6, strict concurrency.

import SwiftUI
@preconcurrency import AppKit

// MARK: - FindReplaceBarView

struct FindReplaceBarView: View {
    @Bindable var controller: FindReplaceController
    @Environment(AppState.self) private var appState

    @FocusState private var queryFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            findRow
            if controller.showReplace {
                replaceRow
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .frame(width: 380)
        .onAppear { queryFieldFocused = true }
        .onChange(of: controller.focusRequestToken) { _, _ in queryFieldFocused = true }
        .onExitCommand { controller.dismiss() }
    }

    // MARK: - Find row

    private var findRow: some View {
        HStack(spacing: 6) {
            TextField("Find", text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: appState.sf(12)))
                .focused($queryFieldFocused)
                .onSubmit {
                    if NSEvent.modifierFlags.contains(.shift) {
                        controller.selectPrevious()
                    } else {
                        controller.selectNext()
                    }
                }
                .onChange(of: controller.query) { _, _ in controller.updateMatches() }
                .frame(minWidth: 110, maxWidth: .infinity)

            optionToggle(symbol: ".*", help: "Use Regular Expression", isOn: $controller.useRegex)
            optionToggle(symbol: "Aa", help: "Match Case", isOn: $controller.caseSensitive)
            optionToggle(symbol: "ab", help: "Match Whole Word", isOn: $controller.wholeWord, underline: true)

            Divider().frame(height: 14)

            Text(controller.statusText)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(controller.isPatternInvalid ? Color.red : Color.secondary)
                .frame(minWidth: 60, alignment: .trailing)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            iconButton("chevron.up", help: "Previous Match (⇧↩)") { controller.selectPrevious() }
                .disabled(controller.matches.isEmpty)
            iconButton("chevron.down", help: "Next Match (↩)") { controller.selectNext() }
                .disabled(controller.matches.isEmpty)

            iconButton(controller.showReplace ? "chevron.down" : "chevron.right",
                       help: controller.showReplace ? "Hide Replace" : "Show Replace") {
                withAnimation(.easeInOut(duration: 0.12)) { controller.showReplace.toggle() }
            }

            iconButton("xmark", help: "Close (Esc)") { controller.dismiss() }
        }
    }

    // MARK: - Replace row

    private var replaceRow: some View {
        HStack(spacing: 6) {
            TextField("Replace", text: $controller.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: appState.sf(12)))
                .onSubmit { controller.replaceCurrent() }
                .frame(minWidth: 110, maxWidth: .infinity)

            iconButton("arrow.turn.down.right", help: "Replace") { controller.replaceCurrent() }
                .disabled(controller.matches.isEmpty)

            Button("Replace All") { controller.replaceAll() }
                .buttonStyle(.plain)
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(controller.matches.isEmpty ? Color.secondary : Color.accentColor)
                .disabled(controller.matches.isEmpty)
        }
    }

    // MARK: - Helpers

    private func optionToggle(
        symbol: String, help: String, isOn: Binding<Bool>, underline: Bool = false
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            controller.updateMatches()
        } label: {
            Text(symbol)
                .font(.system(size: appState.sf(11), weight: .medium, design: .monospaced))
                .underline(underline)
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: appState.sf(11), weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
