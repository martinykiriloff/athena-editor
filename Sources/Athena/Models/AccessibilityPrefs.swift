// AccessibilityPrefs.swift
// Athena — system accessibility preferences (reduce motion, increase contrast) in one place.
// Swift 6, strict concurrency.

@preconcurrency import AppKit
import SwiftUI

enum AccessibilityPrefs {

    // MARK: - System flags

    @MainActor static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    @MainActor static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    // MARK: - Motion

    /// `animation`, or nil (no animation) when Reduce Motion is on.
    @MainActor static func animation(_ animation: Animation) -> Animation? {
        resolve(animation, reduceMotion: reduceMotion)
    }

    /// Pure form for tests.
    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    // MARK: - Contrast

    /// Border/divider opacity: stronger when Increase Contrast is on.
    static func borderOpacity(base: Double, increaseContrast: Bool) -> Double {
        increaseContrast ? min(1, base * 2.5 + 0.2) : base
    }

    /// Selection fill opacity for list rows / tabs.
    static func selectionOpacity(base: Double, increaseContrast: Bool) -> Double {
        increaseContrast ? min(1, base * 2 + 0.15) : base
    }
}
