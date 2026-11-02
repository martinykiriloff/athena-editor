// PackageVersionService.swift
// Athena — latest published version of an npm package via `npm view`, run on
// demand and cached so hovering never spawns a process per hover.
// Swift 6, strict concurrency.

import Foundation

actor PackageVersionService {

    private struct Entry { var version: String?; var fetchedAt: Date }
    private var cache: [String: Entry] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    private let successTTL: TimeInterval = 3600
    private let failureTTL: TimeInterval = 300

    // MARK: - Public

    /// Cached latest version, if still fresh. `.some(nil)` is a cached failure.
    func cached(_ name: String, now: Date = Date()) -> String?? {
        guard let entry = cache[name] else { return nil }
        let ttl = entry.version == nil ? failureTTL : successTTL
        return now.timeIntervalSince(entry.fetchedAt) < ttl ? .some(entry.version) : nil
    }

    /// Latest version of `name`, from cache when fresh, otherwise from one
    /// shared `npm view` (concurrent callers join the same run). Gives up
    /// waiting after `wait` seconds but lets the fetch finish for the cache.
    func latestVersion(of name: String, workingDirectory: URL, wait: TimeInterval = 4) async -> String? {
        guard PackageJSONInspector.isValidPackageName(name) else { return nil }
        if let hit = cached(name) { return hit }

        let task: Task<String?, Never>
        if let running = inflight[name] {
            task = running
        } else {
            task = Task { await Self.npmView(name, in: workingDirectory) }
            inflight[name] = task
            Task { [weak self] in
                let version = await task.value
                await self?.finish(name, version: version)
            }
        }

        return await withTaskGroup(of: String?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                let clock = ContinuousClock()
                try? await clock.sleep(until: clock.now.advanced(by: .seconds(wait)))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Private

    private func finish(_ name: String, version: String?) {
        cache[name] = Entry(version: version, fetchedAt: Date())
        inflight[name] = nil
    }

    /// `npm view <name> version`, through a login shell so nvm/volta/brew
    /// installs are on PATH. The name travels as `$0`, never interpolated.
    /// stdout is drained on a GCD thread before waiting for exit.
    private static func npmView(_ name: String, in directory: URL) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", "npm view --fetch-retries=0 --fetch-timeout=8000 \"$0\" version", name]
                process.currentDirectoryURL = directory
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard process.terminationStatus == 0, let text, !text.isEmpty,
                      text.range(of: #"^\d+\.\d+\.\d+[\w.+-]*$"#, options: .regularExpression) != nil
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: text)
            }
        }
    }
}
