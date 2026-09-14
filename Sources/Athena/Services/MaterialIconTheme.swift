// MaterialIconTheme.swift
// Athena — file and folder icons from the Material Icon Theme (MIT,
//          © Material Extensions), the set VS Code users already know.
// Swift 6, strict concurrency.

import AppKit

/// Resolves a file or folder to its Material icon, and renders it.
///
/// The mapping is the theme's own published table, so an extension Athena
/// has never heard of still gets the right icon. Resolution follows VS
/// Code's order: an exact file name wins over an extension, and the longest
/// extension wins over a shorter one — `Button.stories.tsx` is a Storybook
/// file, not a React one.
@MainActor
final class MaterialIconTheme {

    static let shared = MaterialIconTheme()

    private struct Mapping: Decodable {
        struct Defaults: Decodable {
            var file: String
            var folder: String
            var folderExpanded: String
        }
        var icons: [String: String]
        var fileExtensions: [String: String]
        var fileNames: [String: String]
        var folderNames: [String: String]
        var folderNamesExpanded: [String: String]
        var defaults: Defaults
    }

    private let mapping: Mapping?
    private let iconsDirectory: URL?
    private var renderedCache: [String: NSImage] = [:]

    init() {
        let resources = Self.locateResources()
        iconsDirectory = resources?.appendingPathComponent("icons")
        if let url = resources?.appendingPathComponent("material-icons.json"),
           let data = try? Data(contentsOf: url) {
            mapping = try? JSONDecoder().decode(Mapping.self, from: data)
        } else {
            mapping = nil
        }
    }

    /// Finds the vendored icon set.
    ///
    /// Deliberately not `Bundle.module`: that accessor calls `fatalError`
    /// when the resource bundle is missing, which would turn "the icons
    /// didn't ship" into "the app won't launch". Missing icons should cost
    /// the icons and nothing else, so every candidate location is probed and
    /// `nil` is an acceptable answer.
    static func locateResources() -> URL? {
        let bundleName = "Athena_Athena.bundle"
        let classBundle = Bundle(for: MaterialIconTheme.self)

        // The bundle sits beside the executable in a packaged app, and
        // beside the .xctest bundle when running tests, so each root is
        // probed together with its parent directory.
        var roots: [URL] = []
        for base in [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            classBundle.resourceURL,
            classBundle.bundleURL,
        ].compactMap({ $0 }) {
            roots.append(base)
            roots.append(base.deletingLastPathComponent())
        }

        var candidates: [URL] = []
        for root in roots {
            candidates.append(root.appendingPathComponent("\(bundleName)/Contents/Resources/MaterialIcons"))
            candidates.append(root.appendingPathComponent("\(bundleName)/MaterialIcons"))
            candidates.append(root.appendingPathComponent("MaterialIcons"))
        }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("material-icons.json").path)
        }
    }

    /// Whether the icon set loaded. False only if the resources are missing
    /// from the bundle, in which case callers keep their SF Symbol fallback.
    var isAvailable: Bool { mapping != nil && iconsDirectory != nil }

    // MARK: - Names

    /// The icon name for a file, by exact name then by longest extension.
    func iconName(forFileNamed name: String) -> String {
        guard let mapping else { return "file" }
        if let exact = mapping.fileNames[name] ?? mapping.fileNames[name.lowercased()] { return exact }

        // "Button.stories.tsx" → try "stories.tsx", then "tsx".
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return mapping.defaults.file }
        for start in 1..<parts.count {
            let candidate = parts[start...].joined(separator: ".")
            if let icon = mapping.fileExtensions[candidate] ?? mapping.fileExtensions[candidate.lowercased()] {
                return icon
            }
        }
        return mapping.defaults.file
    }

    /// The icon name for a folder, which has a separate look when open.
    func iconName(forFolderNamed name: String, isExpanded: Bool) -> String {
        guard let mapping else { return isExpanded ? "folder-open" : "folder" }
        let table = isExpanded ? mapping.folderNamesExpanded : mapping.folderNames
        if let match = table[name] ?? table[name.lowercased()] { return match }
        return isExpanded ? mapping.defaults.folderExpanded : mapping.defaults.folder
    }

    // MARK: - Images

    /// The rendered icon for a file, or nil when the set isn't available.
    func image(forFileNamed name: String) -> NSImage? {
        image(named: iconName(forFileNamed: name))
    }

    func image(forFolderNamed name: String, isExpanded: Bool) -> NSImage? {
        image(named: iconName(forFolderNamed: name, isExpanded: isExpanded))
    }

    /// Loads an icon by theme name. Cached: the file tree asks for the same
    /// handful of icons on every row of every render.
    func image(named iconName: String) -> NSImage? {
        if let cached = renderedCache[iconName] { return cached }
        guard let mapping, let iconsDirectory,
              let fileName = mapping.icons[iconName],
              let image = NSImage(contentsOf: iconsDirectory.appendingPathComponent(fileName))
        else { return nil }
        // Template rendering off: these icons carry their own colours, which
        // is the whole point of the set.
        image.isTemplate = false
        renderedCache[iconName] = image
        return image
    }
}
