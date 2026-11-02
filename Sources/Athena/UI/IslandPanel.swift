// IslandPanel.swift
// Rounded, floating panel style ("island") used by the main window layout.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - IslandPanel

/// Fills the view with the theme's panel colour, clips it to a rounded
/// rectangle and adds a hairline border, so it reads as a card floating on
/// the darker window frame.
private struct IslandPanel: ViewModifier {
    @Environment(AppState.self) private var appState

    static let cornerRadius: CGFloat = 10

    func body(content: Content) -> some View {
        content
            .background(appState.panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    /// Presents the view as a rounded island panel.
    func island() -> some View { modifier(IslandPanel()) }
}
