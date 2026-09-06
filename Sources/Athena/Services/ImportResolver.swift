// ImportResolver.swift
// Athena — resolves import/require path strings to actual file URLs.
// Handles relative paths, tsconfig/jsconfig `paths` aliases, pnpm/npm
// workspace packages (with `exports` maps), and node_modules packages.
// Swift 6, strict concurrency.

import Foundation

actor ImportResolver {

    // Extensions tried in order when the import has no extension.
    private static let extensions: [String] = [
        "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "swift", "py", "go", "rs", "rb",
        "css", "scss", "sass", "less",
        "json", "yaml", "yml",
        "vue", "svelte", "astro",
        "md", "mdx",
    ]

    // Index file basenames tried when the resolved path is a directory.
    private static let indexNames: [String] = ["index", "mod", "main"]

    // MARK: - Public

    /// Resolves `importPath` to an existing file URL, or `nil` when nothing
    /// matches. Order: relative/absolute paths, then the nearest
    /// tsconfig/jsconfig `paths` alias, then a workspace package
    /// (`pnpm-workspace.yaml` / package.json `workspaces`), then the nearest
    /// `node_modules`. Bare package imports (`common`, `backend-common/queues`,
    /// `@scope/pkg`) are what a monorepo mostly consists of, so refusing them
    /// made Cmd+click useless there.
    func resolve(_ importPath: String, from fileURL: URL, workspaceURL: URL?) async -> URL? {
        Self.resolveSync(importPath, from: fileURL, workspaceURL: workspaceURL)
    }

    nonisolated static func resolveSync(_ importPath: String, from fileURL: URL, workspaceURL: URL?) -> URL? {
        let spec = importPath.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return nil }
        let baseDir = fileURL.deletingLastPathComponent()

        if spec.hasPrefix(".") {
            return resolveFile(baseDir.appendingPathComponent(spec).standardized)
        }
        if spec.hasPrefix("/") {
            if let ws = workspaceURL, let hit = resolveFile(ws.appendingPathComponent(spec).standardized) { return hit }
            return resolveFile(URL(fileURLWithPath: spec))
        }
        if let hit = resolveViaTSConfig(spec, from: baseDir, workspaceURL: workspaceURL) { return hit }
        if let ws = workspaceURL, let hit = resolveViaWorkspacePackages(spec, workspaceURL: ws) { return hit }
        return resolveViaNodeModules(spec, from: baseDir, workspaceURL: workspaceURL)
    }

    // MARK: - Files

    /// A path with or without extension, or a directory with an index file.
    static func resolveFile(_ candidate: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: candidate.path), !isDir(candidate) { return candidate }
        for ext in extensions {
            let c = candidate.appendingPathExtension(ext)
            if fm.fileExists(atPath: c.path), !isDir(c) { return c }
        }
        if isDir(candidate) {
            for name in indexNames {
                for ext in extensions {
                    let c = candidate.appendingPathComponent(name).appendingPathExtension(ext)
                    if fm.fileExists(atPath: c.path) { return c }
                }
            }
        }
        return nil
    }

    private static func isDir(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
        return flag.boolValue
    }

    // MARK: - tsconfig / jsconfig paths

    /// Walks up from `dir` to the workspace root looking for a tsconfig.json
    /// or jsconfig.json whose (possibly inherited) `compilerOptions.paths`
    /// maps `spec`. Candidates are relative to `baseUrl`, or to the config's
    /// own directory when it has none (TypeScript ≥ 4.1 semantics).
    static func resolveViaTSConfig(_ spec: String, from dir: URL, workspaceURL: URL?) -> URL? {
        var current = dir.standardizedFileURL
        let stop = workspaceURL?.standardizedFileURL.path
        while true {
            for name in ["tsconfig.json", "jsconfig.json"] {
                let configURL = current.appendingPathComponent(name)
                guard let options = compilerOptions(at: configURL, depth: 0) else { continue }
                let base = options.baseUrl.map { current.appendingPathComponent($0).standardized } ?? options.configDir
                for (pattern, targets) in options.paths {
                    guard let star = substitute(spec, pattern: pattern) else { continue }
                    for target in targets {
                        let mapped = target.replacingOccurrences(of: "*", with: star)
                        if let hit = resolveFile(base.appendingPathComponent(mapped).standardized) { return hit }
                    }
                }
            }
            if current.path == stop || current.path == "/" { return nil }
            current = current.deletingLastPathComponent()
        }
    }

    private struct CompilerOptions {
        var baseUrl: String?
        var paths: [String: [String]]
        var configDir: URL
    }

    /// `paths`/`baseUrl` from `configURL`, following `extends` until a
    /// config that defines them is found. `depth` guards a cyclic extends.
    private static func compilerOptions(at configURL: URL, depth: Int) -> CompilerOptions? {
        guard depth < 8, let data = try? Data(contentsOf: configURL),
              let json = parseJSONC(data) else { return nil }
        let dir = configURL.deletingLastPathComponent()
        let options = json["compilerOptions"] as? [String: Any] ?? [:]
        let paths = options["paths"] as? [String: [String]]
        let baseUrl = options["baseUrl"] as? String
        if let paths, !paths.isEmpty {
            return CompilerOptions(baseUrl: baseUrl, paths: paths, configDir: dir)
        }
        // Inherit from `extends` (a relative path, or a package like
        // "@tsconfig/node20/tsconfig.json" found in node_modules).
        guard let parent = json["extends"] as? String else { return nil }
        let parentURL: URL
        if parent.hasPrefix(".") || parent.hasPrefix("/") {
            var url = dir.appendingPathComponent(parent).standardized
            if url.pathExtension.isEmpty { url = url.appendingPathExtension("json") }
            parentURL = url
        } else {
            guard let pkgDir = findInNodeModules(packageDir(of: parent), from: dir, workspaceURL: nil) else { return nil }
            let rest = String(parent.dropFirst(packageDir(of: parent).count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            parentURL = rest.isEmpty ? pkgDir.appendingPathComponent("tsconfig.json") : pkgDir.appendingPathComponent(rest)
        }
        guard var inherited = compilerOptions(at: parentURL, depth: depth + 1) else { return nil }
        // A child baseUrl overrides the parent's; paths came from the parent.
        if let baseUrl { inherited.baseUrl = baseUrl; inherited.configDir = dir }
        return inherited
    }

    /// Matches `spec` against a tsconfig pattern with at most one `*` and
    /// returns the text the star stood for ("" for an exact match).
    static func substitute(_ spec: String, pattern: String) -> String? {
        guard let star = pattern.firstIndex(of: "*") else { return spec == pattern ? "" : nil }
        let prefix = pattern[..<star]
        let suffix = pattern[pattern.index(after: star)...]
        guard spec.hasPrefix(prefix), spec.hasSuffix(suffix),
              spec.count >= prefix.count + suffix.count else { return nil }
        return String(spec.dropFirst(prefix.count).dropLast(suffix.count))
    }

    // MARK: - Workspace packages

    /// `pnpm-workspace.yaml` `packages:` globs, or package.json `workspaces`,
    /// mapped to directories by their package.json `name`.
    static func workspacePackages(in workspaceURL: URL) -> [String: URL] {
        var globs: [String] = []
        if let yaml = try? String(contentsOf: workspaceURL.appendingPathComponent("pnpm-workspace.yaml"), encoding: .utf8) {
            globs = pnpmWorkspaceGlobs(yaml)
        } else if let data = try? Data(contentsOf: workspaceURL.appendingPathComponent("package.json")),
                  let json = parseJSONC(data) {
            if let list = json["workspaces"] as? [String] { globs = list }
            else if let obj = json["workspaces"] as? [String: Any], let list = obj["packages"] as? [String] { globs = list }
        }
        guard !globs.isEmpty else { return [:] }

        let excluded = globs.filter { $0.hasPrefix("!") }.map { String($0.dropFirst()) }
        var result: [String: URL] = [:]
        for glob in globs where !glob.hasPrefix("!") {
            for dir in expandGlob(glob, in: workspaceURL) {
                let rel = dir.path.dropFirst(workspaceURL.standardizedFileURL.path.count + 1)
                if excluded.contains(where: { String(rel) == $0 }) { continue }
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
                      let json = parseJSONC(data), let name = json["name"] as? String else { continue }
                if result[name] == nil { result[name] = dir }
            }
        }
        return result
    }

    /// Lines like `  - 'services/*'` under `packages:`; comments and
    /// exclusions (`!dir`) preserved for the caller.
    static func pnpmWorkspaceGlobs(_ yaml: String) -> [String] {
        var inPackages = false
        var globs: [String] = []
        for rawLine in yaml.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            if line.hasPrefix("packages:") { inPackages = true; continue }
            if inPackages {
                guard line.hasPrefix("-") else { inPackages = false; continue }
                let value = line.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
                if !value.isEmpty { globs.append(value) }
            }
        }
        return globs
    }

    /// `dir/*` and `dir/**` list one level of subdirectories; anything else
    /// is a literal directory.
    private static func expandGlob(_ glob: String, in root: URL) -> [URL] {
        let fm = FileManager.default
        let cleaned = glob.hasSuffix("/") ? String(glob.dropLast()) : glob
        if cleaned.hasSuffix("/*") || cleaned.hasSuffix("/**") {
            let parent = root.appendingPathComponent(String(cleaned[..<cleaned.lastIndex(of: "/")!]))
            let items = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            return items.filter { isDir($0) }.map { $0.standardizedFileURL }
        }
        let dir = root.appendingPathComponent(cleaned).standardized
        return isDir(dir) ? [dir] : []
    }

    static func resolveViaWorkspacePackages(_ spec: String, workspaceURL: URL) -> URL? {
        let name = packageDir(of: spec)
        guard let dir = workspacePackages(in: workspaceURL)[name] else { return nil }
        let subpath = String(spec.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return resolvePackage(at: dir, subpath: subpath)
    }

    // MARK: - node_modules

    static func resolveViaNodeModules(_ spec: String, from dir: URL, workspaceURL: URL?) -> URL? {
        let name = packageDir(of: spec)
        guard let pkgDir = findInNodeModules(name, from: dir, workspaceURL: workspaceURL) else { return nil }
        let subpath = String(spec.dropFirst(name.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return resolvePackage(at: pkgDir, subpath: subpath)
    }

    /// Walks up from `dir` (to the workspace root, or `/`) looking for
    /// `node_modules/<name>`; pnpm's symlinked entries resolve through.
    private static func findInNodeModules(_ name: String, from dir: URL, workspaceURL: URL?) -> URL? {
        var current = dir.standardizedFileURL
        let stop = workspaceURL?.standardizedFileURL.path
        while true {
            let candidate = current.appendingPathComponent("node_modules").appendingPathComponent(name)
            if isDir(candidate) { return candidate.resolvingSymlinksInPath() }
            if current.path == stop || current.path == "/" { return nil }
            current = current.deletingLastPathComponent()
        }
    }

    /// "@scope/pkg/sub" → "@scope/pkg"; "pkg/sub" → "pkg".
    static func packageDir(of spec: String) -> String {
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        if spec.hasPrefix("@"), parts.count >= 2 { return parts[0] + "/" + parts[1] }
        return String(parts[0])
    }

    // MARK: - Package entry points

    /// Source over build output: an `exports`/`types` entry that is a
    /// TypeScript file wins, then `src/<subpath>`, then `main`/`module`,
    /// then a plain file lookup. Jumping into `dist/index.js` is never
    /// what the developer wanted.
    static func resolvePackage(at dir: URL, subpath: String) -> URL? {
        let json = (try? Data(contentsOf: dir.appendingPathComponent("package.json"))).flatMap(parseJSONC) ?? [:]
        let exportsHit = exportsTarget(json["exports"], subpath: subpath).flatMap { resolveFile(dir.appendingPathComponent($0).standardized) }
        if let exportsHit, isSource(exportsHit) { return exportsHit }

        if subpath.isEmpty {
            if let types = (json["types"] ?? json["typings"]) as? String,
               let hit = resolveFile(dir.appendingPathComponent(types).standardized), isSource(hit) { return hit }
            if let hit = resolveFile(dir.appendingPathComponent("src/index")) { return hit }
            if let exportsHit { return exportsHit }
            for key in ["main", "module"] {
                if let entry = json[key] as? String, let hit = resolveFile(dir.appendingPathComponent(entry).standardized) { return hit }
            }
            return resolveFile(dir.appendingPathComponent("index"))
        }

        if let hit = resolveFile(dir.appendingPathComponent("src").appendingPathComponent(subpath)) { return hit }
        if let exportsHit { return exportsHit }
        return resolveFile(dir.appendingPathComponent(subpath))
    }

    private static func isSource(_ url: URL) -> Bool {
        ["ts", "tsx", "mts", "cts"].contains(url.pathExtension) && !url.path.contains("/dist/")
    }

    /// Resolves package.json `exports` for `subpath` ("" = the root "."):
    /// a plain string, a conditions object (types > import > default >
    /// require), or a subpath pattern with one `*`.
    static func exportsTarget(_ exports: Any?, subpath: String) -> String? {
        guard let exports else { return nil }
        let key = subpath.isEmpty ? "." : "./" + subpath
        if let string = exports as? String { return subpath.isEmpty ? string : nil }
        guard let map = exports as? [String: Any] else { return nil }
        // A conditions object at the top level applies to "." only.
        if !map.keys.contains(where: { $0.hasPrefix(".") }) {
            return subpath.isEmpty ? conditionTarget(map) : nil
        }
        if let exact = map[key] { return conditionTarget(exact) }
        for (pattern, value) in map where pattern.contains("*") {
            guard let star = substitute(key, pattern: pattern), let target = conditionTarget(value) else { continue }
            return target.replacingOccurrences(of: "*", with: star)
        }
        return nil
    }

    private static func conditionTarget(_ value: Any) -> String? {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return nil }
        for condition in ["types", "import", "default", "require", "node"] {
            if let nested = object[condition], let target = conditionTarget(nested) { return target }
        }
        return nil
    }

    // MARK: - JSONC

    /// package.json is strict JSON but tsconfig.json routinely carries
    /// comments and trailing commas; strip both outside string literals.
    static func parseJSONC(_ data: Data) -> [String: Any]? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var out = ""
        out.reserveCapacity(text.count)
        var chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            out.append(c)
            i += 1
        }
        // Trailing commas: ",  }" / ",  ]" → "}" / "]".
        chars = Array(out)
        var cleaned = ""
        cleaned.reserveCapacity(chars.count)
        i = 0
        while i < chars.count {
            if chars[i] == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            cleaned.append(chars[i])
            i += 1
        }
        return (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any]
    }
}
