// WorkspaceTrust.swift
// Athena — Workspace Trust model: persisted decisions and the pure gating policy.
// Swift 6, strict concurrency.

import Foundation

// MARK: - State

/// Whether the user has decided to trust the open folder.
enum WorkspaceTrustState: String, Codable, Sendable, Equatable {
    /// No decision yet (prompt pending, or dismissed this launch). Treated as restricted.
    case undecided
    case trusted
    case restricted
}

/// Everything in a workspace that can execute code the user did not write
/// in this session. Each is gated behind the single `isWorkspaceTrusted` check.
enum TrustedAction: String, Sendable, CaseIterable {
    case task
    case npmScript
    case debug
    case workspaceFormatter
    case workspaceLanguageServer
    case sfccUpload

    var title: String {
        switch self {
        case .task:                    return "Running tasks"
        case .npmScript:               return "Running npm scripts"
        case .debug:                   return "Launch and debug configurations"
        case .workspaceFormatter:      return "Workspace Prettier/ESLint binaries"
        case .workspaceLanguageServer: return "Language servers from the workspace"
        case .sfccUpload:              return "SFCC uploads"
        }
    }
}

// MARK: - Persisted record

/// The persisted trust decisions, keyed by canonical folder path.
struct WorkspaceTrustRecord: Codable, Sendable, Equatable {
    var trusted: [String] = []
    var restricted: [String] = []

    func state(for path: String) -> WorkspaceTrustState {
        if trusted.contains(path) { return .trusted }
        if restricted.contains(path) { return .restricted }
        return .undecided
    }

    mutating func set(_ state: WorkspaceTrustState, for path: String) {
        trusted.removeAll { $0 == path }
        restricted.removeAll { $0 == path }
        switch state {
        case .trusted:    trusted.append(path)
        case .restricted: restricted.append(path)
        case .undecided:  break
        }
    }
}

// MARK: - Policy (pure)

enum TrustPolicy {
    /// Symlink-resolved, standardized path, so `~/proj`, `~/proj/` and a
    /// symlink to it share one decision.
    static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// The one rule: only an explicitly trusted workspace may run workspace code.
    static func isAllowed(_ action: TrustedAction, state: WorkspaceTrustState) -> Bool {
        state == .trusted
    }

    /// Text shown inline when `action` is blocked.
    static func blockedMessage(for action: TrustedAction) -> String {
        "Restricted Mode: \(action.title) is disabled. Trust the workspace to enable it (Command Palette: Workspace: Trust This Workspace)."
    }

    /// True when `executablePath` lives inside `workspace` (e.g. `node_modules/.bin/...`).
    static func isInsideWorkspace(executablePath: String, workspace: URL) -> Bool {
        let root = canonicalPath(workspace)
        let exe = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL.path
        return exe == root || exe.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
