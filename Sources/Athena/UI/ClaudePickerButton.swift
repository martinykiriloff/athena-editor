// ClaudePickerButton.swift — Pill/icon trigger + custom-drawn dropdown card used
// in the Claude panel's session bar in place of stock NSMenu / NSPopover chrome.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - ClaudePickerOption

struct ClaudePickerOption<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var detail: String? = nil
    var icon: String? = nil
    var tint: Color = .accentColor
}

// MARK: - Dropdown presentation plumbing

/// An open dropdown, published by its trigger so the panel-level host can
/// draw it above every sibling (the timeline would otherwise cover it) and
/// catch clicks outside it.
struct ClaudeDropdownPresentation {
    let anchor: Anchor<CGRect>
    let width: CGFloat
    /// Opens above the trigger — for triggers near the bottom of the panel.
    let opensUpward: Bool
    let content: AnyView
    let dismiss: () -> Void
}

struct ClaudeDropdownPreferenceKey: PreferenceKey {
    static var defaultValue: [ClaudeDropdownPresentation] { [] }

    static func reduce(value: inout [ClaudeDropdownPresentation], nextValue: () -> [ClaudeDropdownPresentation]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Draws any `ClaudePickerButton` dropdown opened inside this view.
    func claudeDropdownHost() -> some View {
        modifier(ClaudeDropdownHost())
    }
}

private struct ClaudeDropdownHost: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(ClaudeDropdownPreferenceKey.self) { presentations in
            if let presentation = presentations.last {
                GeometryReader { proxy in
                    let trigger = proxy[presentation.anchor]
                    let margin: CGFloat = 8
                    // Right-align under the trigger, clamped inside the panel.
                    let x = min(max(trigger.maxX - presentation.width, margin),
                                max(proxy.size.width - presentation.width - margin, margin))

                    // Upward cards are bottom-aligned to the panel, then
                    // lifted so their bottom edge sits just above the trigger.
                    let upward = presentation.opensUpward
                    let y = upward ? -(proxy.size.height - trigger.minY + 4) : trigger.maxY + 4

                    ZStack(alignment: upward ? .bottomLeading : .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { presentation.dismiss() }

                        presentation.content
                            .frame(width: presentation.width)
                            .offset(x: x, y: y)
                            .transition(
                                .opacity.combined(with: .scale(
                                    scale: 0.96, anchor: upward ? .bottomTrailing : .topTrailing
                                ))
                            )
                    }
                }
            }
        }
    }
}

// MARK: - ClaudePickerButton

struct ClaudePickerButton<ID: Hashable>: View {
    @Environment(AppState.self) private var appState

    /// Pill text; `nil` renders an icon-only round button instead.
    var label: String? = nil
    var icon: String? = nil
    var labelTint: Color = .secondary
    let header: String
    let options: [ClaudePickerOption<ID>]
    var selection: ID? = nil
    var emptyMessage: String = "Nothing here yet"
    var width: CGFloat = 272
    var opensUpward: Bool = false
    let help: String
    let onSelect: (ID) -> Void

    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button {
            setPresented(!isPresented)
        } label: {
            trigger
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help(help)
        .anchorPreference(key: ClaudeDropdownPreferenceKey.self, value: .bounds) { anchor in
            guard isPresented else { return [] }
            return [ClaudeDropdownPresentation(
                anchor: anchor,
                width: appState.sf(width),
                opensUpward: opensUpward,
                content: AnyView(dropdown),
                dismiss: { setPresented(false) }
            )]
        }
    }

    private var triggerFill: Color {
        Color.primary.opacity(isPresented ? 0.12 : (isHovered ? 0.07 : 0))
    }

    @ViewBuilder
    private var trigger: some View {
        if let label {
            HStack(spacing: appState.sf(4)) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: appState.sf(9), weight: .medium))
                }
                Text(label)
                    .font(.system(size: appState.sf(10), weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: appState.sf(7), weight: .bold))
                    .rotationEffect(.degrees(isPresented ? 180 : 0))
                    .opacity(0.7)
            }
            .foregroundStyle(labelTint)
            .padding(.horizontal, appState.sf(8))
            .padding(.vertical, appState.sf(3.5))
            .background(Capsule().fill(triggerFill))
            .contentShape(Capsule())
        } else {
            Image(systemName: icon ?? "ellipsis")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(labelTint)
                .frame(width: appState.sf(22), height: appState.sf(22))
                .background(Circle().fill(triggerFill))
                .contentShape(Circle())
        }
    }

    private var dropdown: some View {
        ClaudePickerDropdown(
            header: header,
            options: options,
            selection: selection,
            emptyMessage: emptyMessage,
            onSelect: { id in
                setPresented(false)
                onSelect(id)
            },
            onDismiss: { setPresented(false) }
        )
        .environment(appState)
    }

    private func setPresented(_ presented: Bool) {
        withAnimation(.easeOut(duration: 0.12)) { isPresented = presented }
    }
}

// MARK: - ClaudePickerDropdown

/// The dropdown card: a listbox with hover/keyboard highlight, like a web
/// select menu. Long lists scroll inside a capped height.
private struct ClaudePickerDropdown<ID: Hashable>: View {
    @Environment(AppState.self) private var appState

    let header: String
    let options: [ClaudePickerOption<ID>]
    let selection: ID?
    let emptyMessage: String
    let onSelect: (ID) -> Void
    let onDismiss: () -> Void

    @State private var highlighted: ID?
    @State private var rowsHeight: CGFloat = 0
    @FocusState private var isFocused: Bool

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: appState.sf(10), style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(header.uppercased())
                .font(.system(size: appState.sf(9), weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, appState.sf(8))
                .padding(.top, appState.sf(3))
                .padding(.bottom, appState.sf(5))

            if options.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: appState.sf(11)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, appState.sf(14))
            } else {
                // Sized to the measured rows so the card hugs its content;
                // only lists taller than the cap scroll.
                let cap = appState.sf(340)
                ScrollViewReader { proxy in
                    ScrollView {
                        rows.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            rowsHeight = $0
                        }
                    }
                    .frame(height: min(rowsHeight, cap))
                    .scrollDisabled(rowsHeight <= cap)
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: highlighted) { _, id in
                        guard let id, rowsHeight > cap else { return }
                        proxy.scrollTo(id)
                    }
                    .onChange(of: rowsHeight) { _, height in
                        if height > cap, let selection { proxy.scrollTo(selection, anchor: .center) }
                    }
                }
            }
        }
        .padding(appState.sf(5))
        .background(cardShape.fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(cardShape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .clipShape(cardShape)
        .shadow(color: .black.opacity(0.22), radius: appState.sf(16), y: appState.sf(8))
        .shadow(color: .black.opacity(0.08), radius: appState.sf(2), y: appState.sf(1))
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            highlighted = selection
            isFocused = true
        }
        .onKeyPress(.upArrow)   { moveHighlight(-1) }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onKeyPress(.return) {
            guard let highlighted else { return .ignored }
            onSelect(highlighted)
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: appState.sf(1)) {
            ForEach(options) { option in
                row(option).id(option.id)
            }
        }
    }

    private func row(_ option: ClaudePickerOption<ID>) -> some View {
        let isSelected    = option.id == selection
        let isHighlighted = option.id == highlighted
        let shape = RoundedRectangle(cornerRadius: appState.sf(6), style: .continuous)

        return Button {
            onSelect(option.id)
        } label: {
            HStack(spacing: appState.sf(9)) {
                if let icon = option.icon {
                    Image(systemName: icon)
                        .font(.system(size: appState.sf(11.5), weight: .medium))
                        .foregroundStyle(option.tint)
                        .frame(width: appState.sf(18))
                }

                VStack(alignment: .leading, spacing: appState.sf(1)) {
                    Text(option.title)
                        .font(.system(size: appState.sf(11.5), weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.system(size: appState.sf(10)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: appState.sf(4))

                if selection != nil {
                    Image(systemName: "checkmark")
                        .font(.system(size: appState.sf(9.5), weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .opacity(isSelected ? 1 : 0)
                }
            }
            .padding(.horizontal, appState.sf(8))
            .padding(.vertical, appState.sf(6))
            .background(shape.fill(isHighlighted ? Color.primary.opacity(0.08) : .clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { highlighted = option.id }
        }
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        guard !options.isEmpty else { return .ignored }
        let current = options.firstIndex { $0.id == highlighted } ?? (delta > 0 ? -1 : options.count)
        let next = (current + delta + options.count) % options.count
        highlighted = options[next].id
        return .handled
    }
}
