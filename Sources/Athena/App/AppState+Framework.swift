// AppState+Framework.swift
// Athena — framework awareness: monorepo layout, route palette, workspace
// package picker, package.json hovers and Tailwind completion glue.
// Swift 6, strict concurrency.

import Foundation

@MainActor
extension AppState {

    // MARK: - Detection

    /// Re-reads the monorepo layout and whether Tailwind is in use; called
    /// when a folder opens.
    func refreshFrameworkInfo() async {
        guard let root = workspace?.rootURL else {
            workspaceLayout = nil
            isTailwindWorkspace = false
            return
        }
        let result = await Task.detached(priority: .utility) {
            (WorkspaceDetector.detect(in: root), TailwindSupport.isTailwindProject(at: root))
        }.value
        workspaceLayout = result.0
        isTailwindWorkspace = result.1
    }

    // MARK: - Routes

    /// ⌘-palette "Go to Route": Next.js app/pages routes of every project
    /// that depends on `next`, plus NestJS controller handlers.
    func presentRoutePalette() async {
        guard let root = workspace?.rootURL else { statusMessage = "Open a folder first"; return }
        let packageDirs = (workspaceLayout?.packages.map(\.directory) ?? [])
        let routes = await Task.detached(priority: .userInitiated) { () -> [FrameworkRoute] in
            var all: [FrameworkRoute] = []
            for dir in [root] + packageDirs where WorkspaceDetector.hasDependency("next", in: dir) {
                all += RouteDiscovery.discover(in: dir)
            }
            all += NestRouteScanner.discover(in: root)
            return all
        }.value
        guard !routes.isEmpty else { statusMessage = "No Next.js or NestJS routes found"; return }

        let rootPath = root.standardizedFileURL.path
        let items = routes.map { route -> FrameworkPaletteItem in
            let path = route.fileURL.path
            let relative = path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : path
            return FrameworkPaletteItem(
                id: route.id,
                title: route.route,
                subtitle: relative,
                badge: route.method ?? route.kind.rawValue,
                icon: route.kind == .page ? "doc.richtext" : "arrow.left.arrow.right",
                target: .file(route.fileURL, line: route.line))
        }
        frameworkPalette = FrameworkPalette(title: "Go to route", items: items)
    }

    // MARK: - Workspace packages

    /// Lists workspace packages that have scripts; picking one makes it the
    /// npm script runner's current package and opens the Scripts panel.
    func presentWorkspacePackagePalette() {
        let runnable = Dictionary(uniqueKeysWithValues: npmPackages.map { ($0.path.deletingLastPathComponent().standardizedFileURL.path, $0) })
        var items: [FrameworkPaletteItem] = []
        if let layout = workspaceLayout {
            for package in layout.packages {
                guard let info = runnable[package.directory.path] else { continue }
                items.append(FrameworkPaletteItem(
                    id: info.id, title: package.name, subtitle: package.relativePath,
                    badge: "\(info.scripts.count) scripts", icon: "shippingbox",
                    target: .npmPackage(id: info.id)))
            }
        }
        if items.isEmpty {
            items = npmPackages.map {
                FrameworkPaletteItem(id: $0.id, title: $0.name, subtitle: $0.path.deletingLastPathComponent().lastPathComponent,
                                     badge: "\($0.scripts.count) scripts", icon: "shippingbox", target: .npmPackage(id: $0.id))
            }
        }
        guard !items.isEmpty else { statusMessage = "No packages with scripts found"; return }
        var title = "Run script in package"
        if let layout = workspaceLayout, layout.isMonorepo {
            title += " (\(layout.manager.rawValue)\(layout.orchestrator.map { " + " + $0.rawValue } ?? ""))"
        }
        frameworkPalette = FrameworkPalette(title: title, items: items)
    }

    func selectFrameworkPaletteItem(_ item: FrameworkPaletteItem) async {
        frameworkPalette = nil
        switch item.target {
        case .file(let url, let line):
            await navigateTo(DefinitionLocation(fileURL: url, line: line, character: 1))
        case .npmPackage(let id):
            selectedNPMPackageId = id
            showBottomPanel = true
            activeBottomPanel = .scripts
        }
    }

    // MARK: - package.json hover

    /// Installed-vs-latest text for the dependency on `line` of an open
    /// package.json; nil for any other file or line. The latest version
    /// comes from `PackageVersionService` (cached `npm view`).
    func packageJSONHover(fileURL: URL, content: String, line: Int) async -> String? {
        guard fileURL.lastPathComponent == "package.json",
              let dep = PackageJSONInspector.dependency(inContent: content, line: line) else { return nil }
        let dir = fileURL.deletingLastPathComponent()
        let installed = PackageJSONInspector.installedVersion(of: dep.name, from: dir)
        let latest = await packageVersionService.latestVersion(of: dep.name, workingDirectory: dir)
        return PackageJSONInspector.hoverText(name: dep.name, spec: dep.spec, installed: installed, latest: latest)
    }

    // MARK: - Tailwind

    /// Class-name completions when the caret (1-based `line`/`col`) is in a
    /// class list and the workspace uses Tailwind.
    func tailwindCompletions(content: String, line: Int, col: Int) -> [CompletionItem] {
        guard isTailwindWorkspace else { return [] }
        let lines = content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return [] }
        let text = lines[line - 1]
        let prefix = String(text.prefix(max(0, col - 1)))
        guard let token = TailwindSupport.classToken(inLinePrefix: prefix), !token.isEmpty else { return [] }
        let wordLength = token.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.count
        return TailwindSupport.completions(forToken: token, wordLength: wordLength)
    }

    // MARK: - Import alias completion

    private static let importPartialRegex = try! NSRegularExpression(
        pattern: #"(?:\bfrom\s*|\bimport\s*\(\s*|\brequire\s*\(\s*|\bimport\s+)['"]([^'"]*)$"#)

    /// Completions for a tsconfig/jsconfig path alias typed inside an import
    /// string (`from "@/comp|"`). The editor replaces only the trailing
    /// identifier run, so each item's insert text is the suggestion minus
    /// everything before that run.
    func importAliasCompletions(content: String, line: Int, col: Int, fileURL: URL) -> [CompletionItem] {
        let lines = content.components(separatedBy: "\n")
        guard line >= 1, line <= lines.count else { return [] }
        let prefix = String(lines[line - 1].prefix(max(0, col - 1)))
        let ns = prefix as NSString
        guard let m = Self.importPartialRegex.firstMatch(in: prefix, range: NSRange(location: 0, length: ns.length)) else { return [] }
        let partial = ns.substring(with: m.range(at: 1))
        guard !partial.hasPrefix(".") else { return [] }
        let wordLength = partial.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.count
        let suggestions = ImportResolver.aliasCompletions(
            forPartial: partial, from: fileURL.deletingLastPathComponent(), workspaceURL: workspace?.rootURL)
        return suggestions.prefix(60).compactMap { suggestion in
            guard suggestion.hasPrefix(partial) else { return nil }
            let insert = String(suggestion.dropFirst(partial.count - wordLength))
            var item = CompletionItem(label: suggestion, kind: "module", detail: "path alias", insertText: insert)
            item.filterText = insert
            item.sortText = suggestion
            return item
        }
    }
}
