// AppState+EditorConfig.swift
// Athena — resolves .editorconfig for tabs and applies save-time transforms.
// Swift 6, strict concurrency.

import Foundation

extension AppState {

    // MARK: - Resolution

    /// Effective .editorconfig settings for `url`, cached per path. Empty when
    /// the feature is off or the file is unsaved. Reads only small
    /// `.editorconfig` files while walking up the directory tree.
    func editorConfig(for url: URL?) -> EditorConfigSettings {
        guard editorUseEditorConfig, let url, url.isFileURL else { return .empty }
        let path = url.path
        if let cached = editorConfigCache[path] { return cached }
        let resolved = EditorConfigFile.resolve(filePath: path) { dir in
            try? String(contentsOfFile: dir + "/.editorconfig", encoding: .utf8)
        }
        editorConfigCache[path] = resolved
        return resolved
    }

    // MARK: - Save transforms

    /// `content` after trim-trailing-whitespace / final-newline / EOL
    /// handling, honouring .editorconfig over the editor-wide toggles.
    func contentPreparedForSave(_ content: String, url: URL) -> String {
        if url.lastPathComponent == ".editorconfig" { editorConfigCache.removeAll() }
        return SaveTransforms.apply(
            to: content,
            trimSetting: editorTrimTrailingWhitespace,
            finalNewlineSetting: editorInsertFinalNewline,
            config: editorConfig(for: url)
        )
    }
}
