// FrameworkAwareness.swift
// Athena — pure scanners for framework conventions: workspace/monorepo
// layout, Next.js app/pages routes, NestJS controller routes, package.json
// dependency lines. No actor state; callers run them off the main thread.
// Swift 6, strict concurrency.

import Foundation

// MARK: - Workspace detection

enum WorkspaceDetector {

    /// Package manager, orchestrator (turbo/nx/lerna) and the workspace's
    /// packages. Package discovery reuses `ImportResolver.workspacePackages`
    /// (pnpm-workspace.yaml / package.json `workspaces`) so Cmd+click and
    /// the package picker agree on what a workspace package is.
    static func detect(in root: URL) -> WorkspaceLayout {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(name).path) }

        let manager: NPMPackageManager
        if exists("pnpm-workspace.yaml") || exists("pnpm-lock.yaml") { manager = .pnpm }
        else if exists("yarn.lock") { manager = .yarn }
        else { manager = .npm }

        let orchestrator: WorkspaceLayout.Orchestrator?
        if exists("turbo.json") { orchestrator = .turbo }
        else if exists("nx.json") { orchestrator = .nx }
        else if exists("lerna.json") { orchestrator = .lerna }
        else { orchestrator = nil }

        let rootPath = root.standardizedFileURL.path
        let packages = ImportResolver.workspacePackages(in: root)
            .map { name, dir -> WorkspacePackage in
                let path = dir.standardizedFileURL.path
                let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
                return WorkspacePackage(name: name, directory: dir.standardizedFileURL,
                                        relativePath: relative, scriptNames: scriptNames(in: dir))
            }
            .sorted { $0.relativePath < $1.relativePath }
        return WorkspaceLayout(manager: manager, orchestrator: orchestrator, packages: packages)
    }

    static func scriptNames(in dir: URL) -> [String] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
              let json = ImportResolver.parseJSONC(data),
              let scripts = json["scripts"] as? [String: Any] else { return [] }
        return scripts.keys.sorted()
    }

    /// Whether `dir`'s package.json lists `name` in any dependency section.
    static func hasDependency(_ name: String, in dir: URL) -> Bool {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
              let json = ImportResolver.parseJSONC(data) else { return false }
        return ["dependencies", "devDependencies", "peerDependencies"].contains {
            (json[$0] as? [String: Any])?[name] != nil
        }
    }
}

// MARK: - Directory walking

enum ProjectWalker {
    static let skippedDirectories: Set<String> = [
        "node_modules", ".git", ".next", "dist", "build", ".turbo", ".nx", "coverage", ".build", ".output", ".svelte-kit",
    ]

    /// Regular files under `root` (depth-first, skipping dependency/build
    /// directories) whose names satisfy `include`, capped at `limit`.
    static func files(under root: URL, limit: Int = 5000, include: (String) -> Bool) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if include(url.lastPathComponent) {
                result.append(url)
                if result.count >= limit { break }
            }
        }
        return result
    }
}

// MARK: - Next.js routes

enum RouteDiscovery {

    private static let sourceExtensions: Set<String> = ["ts", "tsx", "js", "jsx", "mdx"]
    private static let routeRoots = ["app", "src/app", "pages", "src/pages"]

    /// Every page and API route of the Next.js project at `projectRoot`,
    /// sorted by route. `app/` (app router) and `pages/` (pages router) may
    /// coexist.
    static func discover(in projectRoot: URL) -> [FrameworkRoute] {
        var routes: [FrameworkRoute] = []
        for rootName in routeRoots {
            let dir = projectRoot.appendingPathComponent(rootName)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let isApp = rootName.hasSuffix("app")
            let dirPath = dir.standardizedFileURL.path
            for file in ProjectWalker.files(under: dir, include: { sourceExtensions.contains(($0 as NSString).pathExtension) }) {
                let path = file.standardizedFileURL.path
                guard path.hasPrefix(dirPath + "/") else { continue }
                let relative = String(path.dropFirst(dirPath.count + 1))
                guard let (route, kind) = isApp ? appRoute(forRelativePath: relative) : pagesRoute(forRelativePath: relative)
                else { continue }
                routes.append(FrameworkRoute(route: route, kind: kind, framework: .next, fileURL: file.standardizedFileURL))
            }
        }
        return routes.sorted { ($0.route, $0.fileURL.path) < ($1.route, $1.fileURL.path) }
    }

    /// Route for a file path relative to `app/`: only `page.*` (a page) and
    /// `route.*` (a route handler) define URLs. Route groups `(x)` and
    /// parallel-route slots `@x` do not appear in the URL; intercepting
    /// routes `(.)x` are skipped (they re-render another route).
    static func appRoute(forRelativePath relative: String) -> (String, FrameworkRoute.Kind)? {
        var parts = relative.split(separator: "/").map(String.init)
        guard let file = parts.popLast() else { return nil }
        let stem = (file as NSString).deletingPathExtension
        let kind: FrameworkRoute.Kind
        switch stem {
        case "page":  kind = .page
        case "route": kind = .api
        default:      return nil
        }
        var segments: [String] = []
        for part in parts {
            if part.hasPrefix("(.") { return nil }                          // intercepting route
            if part.hasPrefix("(") && part.hasSuffix(")") { continue }      // route group
            if part.hasPrefix("@") { continue }                             // parallel slot
            if part.hasPrefix("_") { return nil }                           // private folder
            segments.append(part)
        }
        return ("/" + segments.joined(separator: "/"), kind)
    }

    /// Route for a file path relative to `pages/`. `_app`, `_document` and
    /// co. are not routes; `index` collapses into its directory; `api/…` are
    /// API routes.
    static func pagesRoute(forRelativePath relative: String) -> (String, FrameworkRoute.Kind)? {
        var parts = relative.split(separator: "/").map(String.init)
        guard let file = parts.popLast() else { return nil }
        let stem = (file as NSString).deletingPathExtension
        if stem.hasPrefix("_") { return nil }
        if stem.contains(".test") || stem.contains(".spec") { return nil }
        if stem != "index" { parts.append(stem) }
        let isAPI = parts.first == "api"
        return ("/" + parts.joined(separator: "/"), isAPI ? .api : .page)
    }
}

// MARK: - NestJS routes

enum NestRouteScanner {

    private static let controllerRegex = try! NSRegularExpression(
        pattern: #"@Controller\(\s*(?:['"`]([^'"`]*)['"`]|\{[^}]*?path:\s*['"`]([^'"`]*)['"`][^}]*\})?\s*\)"#)
    private static let handlerRegex = try! NSRegularExpression(
        pattern: #"@(Get|Post|Put|Patch|Delete|Head|Options|All)\(\s*(?:['"`]([^'"`]*)['"`])?\s*\)"#)

    /// Handlers declared in `text`, each with its controller prefix joined
    /// on. Decorators are matched textually, so a decorator inside a comment
    /// or string is a false positive.
    static func routes(in text: String, fileURL: URL) -> [FrameworkRoute] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let controllers = controllerRegex.matches(in: text, range: full)
        guard !controllers.isEmpty else { return [] }

        func capture(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func line(at location: Int) -> Int {
            1 + ns.substring(to: location).reduce(into: 0) { if $1 == "\n" { $0 += 1 } }
        }

        var result: [FrameworkRoute] = []
        for (i, controller) in controllers.enumerated() {
            let prefix = capture(controller, 1) ?? capture(controller, 2) ?? ""
            let end = i + 1 < controllers.count ? controllers[i + 1].range.location : ns.length
            let span = NSRange(location: NSMaxRange(controller.range), length: end - NSMaxRange(controller.range))
            for handler in handlerRegex.matches(in: text, range: span) {
                guard let verb = capture(handler, 1) else { continue }
                let path = capture(handler, 2) ?? ""
                result.append(FrameworkRoute(
                    route: join(prefix, path), kind: .handler, framework: .nest,
                    fileURL: fileURL, line: line(at: handler.range.location), method: verb.uppercased()))
            }
        }
        return result
    }

    static func join(_ prefix: String, _ path: String) -> String {
        let parts = (prefix + "/" + path).split(separator: "/").map(String.init)
        return "/" + parts.joined(separator: "/")
    }

    /// Routes of every `*.controller.ts` under `root`.
    static func discover(in root: URL) -> [FrameworkRoute] {
        let files = ProjectWalker.files(under: root, limit: 2000) { $0.hasSuffix(".controller.ts") }
        var all: [FrameworkRoute] = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            all += routes(in: text, fileURL: file.standardizedFileURL)
        }
        return all.sorted { ($0.route, $0.method ?? "") < ($1.route, $1.method ?? "") }
    }
}

// MARK: - package.json dependency lines

enum PackageJSONInspector {

    private static let sections: Set<String> = ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"]
    private static let entryRegex = try! NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*:\s*"([^"]*)"\s*,?\s*$"#)
    private static let sectionRegex = try! NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*:\s*\{"#)

    /// The dependency declared on 1-based `line` of a package.json, or nil
    /// when that line isn't an entry of a dependency section.
    static func dependency(inContent content: String, line: Int) -> (name: String, spec: String)? {
        let lines = content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return nil }
        let text = lines[line - 1]
        let ns = text as NSString
        guard let m = entryRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let name = ns.substring(with: m.range(at: 1)), spec = ns.substring(with: m.range(at: 2))

        var i = line - 2
        while i >= 0 {
            let above = lines[i]
            let trimmed = above.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("}") { return nil }
            let aboveNS = above as NSString
            if let s = sectionRegex.firstMatch(in: above, range: NSRange(location: 0, length: aboveNS.length)) {
                return sections.contains(aboveNS.substring(with: s.range(at: 1))) ? (name, spec) : nil
            }
            i -= 1
        }
        return nil
    }

    /// Version of `name` installed for the package at `packageDir`, found by
    /// walking up through parent `node_modules` (hoisted monorepo installs).
    static func installedVersion(of name: String, from packageDir: URL) -> String? {
        var dir = packageDir.standardizedFileURL
        while true {
            let manifest = dir.appendingPathComponent("node_modules/\(name)/package.json")
            if let data = try? Data(contentsOf: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = json["version"] as? String { return version }
            // `deletingLastPathComponent` of "/" yields "/.." forever, so stop at the root explicitly.
            if dir.path == "/" { return nil }
            dir = dir.deletingLastPathComponent().standardizedFileURL
        }
    }

    /// A valid npm package name — checked before `name` reaches a process.
    static func isValidPackageName(_ name: String) -> Bool {
        name.range(of: #"^(@[a-z0-9-~][a-z0-9-._~]*/)?[a-z0-9-~][a-z0-9-._~]*$"#, options: .regularExpression) != nil
    }

    /// True when `latest` is a higher major.minor.patch than `installed`.
    static func isNewer(_ latest: String, than installed: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            let core = v.prefix { $0.isNumber || $0 == "." }
            return core.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        }
        let a = parts(latest), b = parts(installed)
        for i in 0..<3 {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Hover text for a dependency: declared range, installed and latest.
    static func hoverText(name: String, spec: String, installed: String?, latest: String?) -> String {
        var lines = ["\(name)  \(spec)"]
        lines.append("Installed: " + (installed ?? "not found in node_modules"))
        if let latest {
            var row = "Latest: \(latest)"
            if let installed, isNewer(latest, than: installed) { row += "  (update available)" }
            lines.append(row)
        } else {
            lines.append("Latest: unavailable (npm view failed or timed out)")
        }
        return lines.joined(separator: "\n")
    }
}
