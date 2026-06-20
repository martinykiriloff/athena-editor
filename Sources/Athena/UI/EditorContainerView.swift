// EditorContainerView.swift
// Athena — central editor area: tab bar + active editor or welcome screen.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - EditorContainerView

struct EditorContainerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()
            Divider()
            editorContent
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        if appState.activeTab != nil {
            CodeEditorView(tab: activeTabBinding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            WelcomeView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// A binding to the active tab's content that round-trips writes through
    /// `AppState.updateTabContent` so the dirty flag is maintained correctly.
    private var activeTabBinding: Binding<TabModel> {
        Binding {
            appState.activeTab ?? TabModel.untitled()
        } set: { updated in
            guard let id = appState.activeTabId else { return }
            appState.updateTabContent(id, content: updated.content)
        }
    }
}

// MARK: - CodeEditorView

/// Bridges the active TabModel binding to the NSTextView-based EditorView.
struct CodeEditorView: View {
    @Binding var tab: TabModel
    @Environment(AppState.self) private var appState

    @State private var scrollFraction:  Double = 0
    @State private var visibleFraction: Double = 0.2
    @State private var scrollProxy:     EditorScrollProxy? = nil

    private var blameInfo: [Int: BlameLine] {
        guard let url = tab.fileURL else { return [:] }
        return appState.blameCache[url.path] ?? [:]
    }

    var body: some View {
        HStack(spacing: 0) {
            EditorView(
                content: $tab.content,
                language: tab.language,
                theme: appState.currentTheme,
                fontSize:         appState.editorFontSize,
                fontFamily:       appState.editorFontFamily,
                fontLigatures:    appState.editorFontLigatures,
                lineHeight:       appState.editorLineHeight,
                wordWrap:         appState.editorWordWrap,
                renderWhitespace: appState.editorRenderWhitespace,
                tabSize:          appState.editorTabSize,
                insertSpaces:     appState.editorInsertSpaces,
                blameInfo:        blameInfo,
                fileURL:          tab.fileURL,
                onCursorMove: { line, col in
                    guard let idx = appState.openTabs.firstIndex(where: { $0.id == tab.id }) else { return }
                    appState.openTabs[idx].cursorLine   = line
                    appState.openTabs[idx].cursorColumn = col
                },
                onContentChange: { newContent in
                    appState.updateTabContent(tab.id, content: newContent)
                },
                onScrollChange: { fraction, visible in
                    scrollFraction  = fraction
                    visibleFraction = visible
                },
                onImportClick: { importPath, fileURL in
                    guard let fileURL else { return }
                    Task { await appState.openImportedFile(importPath, from: fileURL) }
                },
                scrollProxy: $scrollProxy
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: tab.id) { await appState.loadBlame(for: tab) }

            if appState.editorMinimapEnabled {
                MinimapView(
                    content: tab.content,
                    language: tab.language,
                    theme: appState.currentTheme,
                    scrollFraction: scrollFraction,
                    visibleFraction: visibleFraction,
                    onJump: { fraction in
                        scrollProxy?.scrollTo(fraction: fraction)
                    }
                )
                .frame(width: 100)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// WelcomeView is defined in UI/WelcomeView.swift.
