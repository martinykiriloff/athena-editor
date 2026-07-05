// SearchService.swift
// Athena — workspace search backed by ripgrep, with grep fallback.
// Swift 6, strict concurrency.

import Foundation

// MARK: - SearchFilter

struct SearchFilter: Sendable {
    /// Comma-separated globs to include, e.g. "*.swift, src/**"
    var include: String = ""
    /// Comma-separated globs to exclude, e.g. "node_modules, .build, *.lock"
    var exclude: String = ""

    var includeItems: [String] {
        include.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var excludeItems: [String] {
        exclude.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: - SearchService

actor SearchService {

    private var currentTask: Task<Void, Never>?

    // MARK: - Public API

    /// Builds the stream via `AsyncStream.makeStream()` rather than the
    /// `AsyncStream { continuation in ... }` initializer so `currentTask` is
    /// stored as a plain, synchronous actor-isolated assignment instead of
    /// through a nested `Task` — that nested-Task hop raced `cancel()`: a
    /// call landing before the nested Task ran would find `currentTask` still
    /// nil and silently fail to cancel the in-flight search.
    func search(
        query: String,
        in url: URL,
        regex: Bool,
        caseSensitive: Bool,
        filter: SearchFilter = SearchFilter()
    ) -> AsyncStream<SearchResult> {
        let (stream, continuation) = AsyncStream<SearchResult>.makeStream()
        let task = Task {
            if let rg = rgExecutable() {
                await self.runRipgrep(
                    rg, query: query, url: url,
                    regex: regex, caseSensitive: caseSensitive,
                    filter: filter, continuation: continuation
                )
            } else {
                await self.runGrep(
                    query: query, url: url,
                    regex: regex, caseSensitive: caseSensitive,
                    filter: filter, continuation: continuation
                )
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        currentTask = task
        return stream
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - ripgrep

    private func runRipgrep(
        _ rg: String,
        query: String,
        url: URL,
        regex: Bool,
        caseSensitive: Bool,
        filter: SearchFilter,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        var args: [String] = ["--line-number", "--no-heading", "--color=never", "--with-filename"]
        if !caseSensitive { args.append("--ignore-case") }
        if !regex         { args.append("--fixed-strings") }

        for item in filter.includeItems {
            args += ["--glob", item]
        }
        for item in filter.excludeItems {
            // Items that look like extensions → !*.ext; dirs → !dir/**
            let glob = item.contains("*") ? item : (item.contains(".") ? item : "\(item)/**")
            args += ["--glob", "!\(glob)"]
        }

        args += [query, url.path]
        await runProcess(executableURL: URL(fileURLWithPath: rg), arguments: args, continuation: continuation)
    }

    // MARK: - grep fallback

    private func runGrep(
        query: String,
        url: URL,
        regex: Bool,
        caseSensitive: Bool,
        filter: SearchFilter,
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        var args: [String] = ["-rn", "--binary-files=without-match", "--with-filename"]
        if !caseSensitive { args.append("-i") }
        if !regex         { args.append("-F") }

        for item in filter.includeItems {
            if item.contains("*") {
                args += ["--include=\(item)"]
            }
            // directory includes handled by scoping the search path instead
        }

        // Default exclusions + user exclusions
        let defaultExcludeDirs = [".git", ".build", "node_modules", ".swiftpm", "DerivedData", ".hg", ".svn"]
        for dir in defaultExcludeDirs {
            args += ["--exclude-dir=\(dir)"]
        }
        for item in filter.excludeItems {
            if item.contains("*") {
                args += ["--exclude=\(item)"]
            } else {
                args += ["--exclude-dir=\(item)"]
            }
        }

        // If user specified include-only folders, search those sub-paths instead of root
        let includeFolders = filter.includeItems.filter { !$0.contains("*") }
        let searchPaths: [String] = includeFolders.isEmpty
            ? [url.path]
            : includeFolders.map { url.appendingPathComponent($0).path }

        args.append(query)
        args += searchPaths

        await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/grep"),
            arguments: args,
            continuation: continuation
        )
    }

    // MARK: - Shared process runner + output parser

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        continuation: AsyncStream<SearchResult>.Continuation
    ) async {
        let process = Process()
        process.executableURL = executableURL
        process.arguments     = arguments

        let pipe   = Pipe()
        let errPipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = errPipe

        do { try process.run() } catch { return }

        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if Task.isCancelled { break }
            let str = String(line)

            // Format: <path>:<lineNumber>:<content>
            // Paths may contain ':' so split on the first two ':' only.
            guard let firstColon = str.firstIndex(of: ":") else { continue }
            let afterFirst = str.index(after: firstColon)
            guard afterFirst < str.endIndex,
                  let secondColon = str[afterFirst...].firstIndex(of: ":")
            else { continue }

            let filePath    = String(str[..<firstColon])
            let lineNumStr  = String(str[afterFirst..<secondColon])
            let lineContent = String(str[str.index(after: secondColon)...])

            guard let lineNumber = Int(lineNumStr), !filePath.isEmpty else { continue }

            continuation.yield(SearchResult(
                filePath:    filePath,
                lineNumber:  lineNumber,
                lineContent: lineContent,
                matchRange:  NSRange(location: 0, length: 0)
            ))
        }
    }

    // MARK: - Tool discovery

    private func rgExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg",
            "\(NSHomeDirectory())/.local/bin/rg",
            "\(NSHomeDirectory())/.cargo/bin/rg",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
