// ClaudeSessionStore.swift
// Athena — lists resumable Claude Code conversations from the CLI's own store.
// Swift 6, strict concurrency.

import Foundation

// MARK: - ClaudeStoredSession

/// A past conversation the CLI can resume by id.
struct ClaudeStoredSession: Identifiable, Sendable, Equatable {
    let id: String
    let cwd: String
    /// First thing the user asked, used as the conversation's title.
    let title: String
    let modifiedAt: Date

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Untitled conversation" }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }
}

// MARK: - ClaudeSessionStore

/// Reads the transcript files Claude Code writes under
/// `~/.claude/projects/<escaped-cwd>/<session-id>.jsonl`.
///
/// The CLI owns this format; Athena only reads it, and only enough of each
/// file to title the entry — so an unfamiliar or changed layout degrades to an
/// empty history list rather than an error.
actor ClaudeSessionStore {

    /// Lines scanned per transcript before giving up on finding a title —
    /// bounded so a huge conversation can't stall the picker.
    private static let maxScannedLines = 400

    /// The most recent conversations rooted at `workspace`, newest first.
    func recentSessions(
        workspace: URL,
        account: ClaudeAccount,
        limit: Int = 15
    ) -> [ClaudeStoredSession] {
        let projectsRoot = Self.configRoot(for: account).appending(path: "projects")
        let fm = FileManager.default

        guard let directories = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        // The CLI's directory naming is its own business, so prefer the
        // expected name but fall back to matching each transcript's recorded
        // `cwd` — which is authoritative either way.
        let expected = Self.escapedDirectoryName(for: workspace)
        let candidates = directories.filter { $0.lastPathComponent == expected }
        let searchRoots = candidates.isEmpty ? directories : candidates

        var sessions: [ClaudeStoredSession] = []
        for root in searchRoots {
            sessions += transcripts(in: root, matching: workspace.path)
        }

        return sessions
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Private

    private func transcripts(in directory: URL, matching cwd: String) -> [ClaudeStoredSession] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Newest first, so the scan cost is bounded by `limit` in practice.
        let transcripts = files
            .filter { $0.pathExtension == "jsonl" }
            .map { url -> (URL, Date) in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(40)

        return transcripts.compactMap { url, date in
            guard let summary = Self.summarize(transcript: url), summary.cwd == cwd else { return nil }
            return ClaudeStoredSession(
                id: url.deletingPathExtension().lastPathComponent,
                cwd: summary.cwd,
                title: summary.title,
                modifiedAt: date
            )
        }
    }

    /// Pulls the working directory and the opening user prompt out of a
    /// transcript without loading the whole file.
    private static func summarize(transcript url: URL) -> (cwd: String, title: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // 256 KB comfortably covers the header plus the first few turns.
        guard let data = try? handle.read(upToCount: 256 * 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var cwd: String?
        var title: String?

        for line in text.components(separatedBy: .newlines).prefix(maxScannedLines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if cwd == nil, let value = object["cwd"] as? String { cwd = value }
            if title == nil, let text = firstUserText(in: object) { title = text }
            if cwd != nil && title != nil { break }
        }

        guard let cwd else { return nil }
        return (cwd, title ?? "")
    }

    /// The text of a user turn, skipping the tool results and meta entries
    /// that share the same `user` type in the transcript.
    private static func firstUserText(in object: [String: Any]) -> String? {
        guard object["type"] as? String == "user",
              object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return nil }

        if let text = message["content"] as? String {
            return text.hasPrefix("<") ? nil : text
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        for block in blocks where block["type"] as? String == "text" {
            guard let text = block["text"] as? String, !text.hasPrefix("<") else { continue }
            return text
        }
        return nil
    }

    /// `~/.claude`, or the account's own config root.
    static func configRoot(for account: ClaudeAccount) -> URL {
        if let dir = account.configDirectory {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude")
    }

    /// The CLI's project-directory name for a working directory: every path
    /// separator and dot becomes a dash.
    static func escapedDirectoryName(for url: URL) -> String {
        url.path
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
    }
}
