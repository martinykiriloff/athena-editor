// MaterialFileIcon.swift
// Athena — the Material Icon Theme glyph for one file or folder, with the
//          previous SF Symbol as the fallback when the set isn't available.
// Swift 6, strict concurrency.

import SwiftUI

struct MaterialFileIcon: View {
    let url: URL?
    var isDirectory: Bool = false
    var isExpanded: Bool = false
    var size: CGFloat = 14
    /// Drawn when the icon set is missing, so the UI never loses its icons.
    var fallbackSystemName: String = "doc.text.fill"
    var fallbackColor: Color = .secondary

    var body: some View {
        if let image = themeImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSystemName)
                .foregroundColor(fallbackColor)
        }
    }

    private var themeImage: NSImage? {
        let theme = MaterialIconTheme.shared
        guard theme.isAvailable else { return nil }
        let name = url?.lastPathComponent ?? ""
        return isDirectory
            ? theme.image(forFolderNamed: name, isExpanded: isExpanded)
            : theme.image(forFileNamed: name)
    }
}
