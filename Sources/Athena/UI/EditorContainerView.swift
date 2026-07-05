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
        VStack(spacing: 0) {
            // Show debug toolbar whenever a session is active.
            if appState.debugState != .idle && appState.debugState != .stopped {
                DebugToolbarView()
            }

            if appState.activeTab != nil {
                CodeEditorView(tab: activeTabBinding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WelcomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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
    @State private var findReplaceController: FindReplaceController? = nil

    private var blameInfo: [Int: BlameLine] {
        guard let url = tab.fileURL else { return [:] }
        return appState.blameCache[url.path] ?? [:]
    }

    private var fileBreakpoints: Set<Int> {
        guard let path = tab.fileURL?.path else { return [] }
        return appState.debugBreakpoints[path] ?? []
    }

    private var fileDebugLine: Int? {
        guard let path = tab.fileURL?.path,
              appState.debugCurrentFile?.path == path else { return nil }
        return appState.debugCurrentLine
    }

    var body: some View {
        VStack(spacing: 0) {
            if tab.externallyModified {
                ExternalChangeBanner(tab: tab)
            }
            editorRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorRow: some View {
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
                autoIndent:       appState.editorAutoIndent,
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
                onRequestDefinition: { line, col in
                    guard let fileURL = tab.fileURL else { return nil }
                    return try? await appState.lspManager.definition(
                        fileURL: fileURL, line: line - 1, character: col - 1
                    )
                },
                onOpenDefinitionFile: { url in
                    await appState.openFile(url)
                },
                onRequestHover: { line, col in
                    guard let fileURL = tab.fileURL else { return nil }
                    return try? await appState.lspManager.hover(
                        fileURL: fileURL, line: line - 1, character: col - 1
                    )
                },
                onFindReferences: { line, col in
                    guard let fileURL = tab.fileURL else { return }
                    await appState.findReferences(fileURL: fileURL, line: line - 1, character: col - 1)
                },
                onRenameSymbol: { line, col, newName in
                    guard let fileURL = tab.fileURL else { return }
                    await appState.renameSymbol(
                        fileURL: fileURL, line: line - 1, character: col - 1, newName: newName
                    )
                },
                pendingNavigationTarget: appState.pendingNavigationTarget,
                onNavigationConsumed: { appState.pendingNavigationTarget = nil },
                scrollProxy: $scrollProxy,
                findReplaceProxy: $findReplaceController,
                breakpoints: fileBreakpoints,
                debugLine:   fileDebugLine,
                onToggleBreakpoint: { line in
                    guard let path = tab.fileURL?.path else { return }
                    appState.toggleBreakpoint(filePath: path, line: line)
                },
                onRequestCompletion: { line, col in
                    // LSP completions (0-indexed internally)
                    let lspItems: [CompletionItem]
                    if let fileURL = tab.fileURL {
                        lspItems = (try? await appState.lspManager.complete(
                            fileURL: fileURL, line: line - 1, character: col - 1
                        )) ?? []
                    } else {
                        lspItems = []
                    }
                    // Drizzle ORM completions
                    let drizzleItems: [CompletionItem]
                    if let fileURL = tab.fileURL {
                        drizzleItems = await appState.drizzleService.complete(
                            text: tab.content, line: line, col: col, fileURL: fileURL
                        )
                    } else {
                        drizzleItems = []
                    }
                    // Merge: Drizzle first, then LSP; deduplicate by label
                    var seen = Set<String>()
                    return (drizzleItems + lspItems).filter { seen.insert($0.label).inserted }
                },
                onRequestGhostText: { prefix, suffix in
                    await appState.requestInlineCompletion(prefix: prefix, suffix: suffix)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: tab.id) { await appState.loadBlame(for: tab) }
            .overlay(alignment: .topTrailing) {
                if let controller = findReplaceController, controller.isVisible {
                    FindReplaceBarView(controller: controller)
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                }
            }

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

// MARK: - ExternalChangeBanner

/// Shown above the editor when `tab`'s backing file changed on disk while the
/// tab had unsaved edits (see `AppState.handleExternalFileChange`) — the
/// silent-reload path can't run without discarding those edits, so this asks
/// the user instead.
private struct ExternalChangeBanner: View {
    let tab: TabModel
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("\(tab.title) changed on disk.")
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer()

            Button("Keep My Changes") {
                appState.keepLocalChanges(tab.id)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .font(.system(size: 12))

            Button("Reload") {
                Task { await appState.reloadTabFromDisk(tab.id) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.orange.opacity(0.15))
        .overlay(alignment: .bottom) { Divider() }
    }
}

// WelcomeView is defined in UI/WelcomeView.swift.
