// AppState+Trust.swift
// Athena — Workspace Trust: prompt, restricted mode and the single gating check.
// Swift 6, strict concurrency.

import Foundation

// MARK: - TrustCenter

/// Trust state for the open workspace. A separate object (held by `AppState`
/// as `trust`) because an extension can't add stored properties.
@Observable @MainActor
final class TrustCenter {
    var state: WorkspaceTrustState = .undecided
    var promptPresented = false
    /// Last action that was refused, for the banner.
    var lastBlocked: TrustedAction?
    @ObservationIgnored let service: WorkspaceTrustService

    init(settings: SettingsService) {
        service = WorkspaceTrustService(settings: settings)
    }
}

// MARK: - AppState

@MainActor
extension AppState {

    /// The single check every gated feature uses. No workspace open means
    /// there is nothing workspace-controlled to run.
    var isWorkspaceTrusted: Bool {
        workspace == nil || trust.state == .trusted
    }

    var isRestrictedMode: Bool { workspace != nil && trust.state != .trusted }

    /// Returns true when `action` may proceed; otherwise explains why, inline.
    @discardableResult
    func requireTrust(for action: TrustedAction) -> Bool {
        if isWorkspaceTrusted { return true }
        let message = TrustPolicy.blockedMessage(for: action)
        statusMessage = message
        trust.lastBlocked = action
        if action == .task || action == .npmScript {
            scriptOutput += "\n[trust] \(message)\n"
        }
        return false
    }

    /// Called from `openWorkspace`: applies a stored decision or asks.
    func evaluateTrust(for url: URL) async {
        trust.state = .undecided
        trust.lastBlocked = nil
        await lspManager.setWorkspaceTrusted(false)
        let stored = await trust.service.state(for: url)
        trust.state = stored
        if stored == .undecided {
            trust.promptPresented = true
        } else {
            await lspManager.setWorkspaceTrusted(stored == .trusted)
        }
    }

    /// Persists and applies the user's choice.
    func setTrust(_ state: WorkspaceTrustState) async {
        guard let url = workspace?.rootURL else { return }
        trust.state = state
        trust.promptPresented = false
        trust.lastBlocked = nil
        await trust.service.set(state, for: url)
        await lspManager.setWorkspaceTrusted(state == .trusted)
        statusMessage = state == .trusted
            ? "Workspace trusted."
            : "Restricted Mode: workspace code will not run."
    }

    /// Command palette / menu entry.
    func presentTrustPrompt() {
        guard workspace != nil else { statusMessage = "Open a folder first."; return }
        trust.promptPresented = true
    }
}
