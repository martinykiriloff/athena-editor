// EditorContainerView.swift
// Athena — central editor area: tab bar(s) + active editor(s) or welcome screen.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - EditorContainerView

/// Renders one editor pane (single-pane, today's default) or two side-by-side
/// panes once `AppState.secondaryGroup` exists (plan.md item 22, "Split
/// Editor Right" — ⌘\). A single shared breadcrumb bar sits above whichever
/// layout is active, reflecting `AppState.focusedTab` (the pane last
/// interacted with) rather than a per-pane bar — the smallest architectural
/// footprint for a feature VS Code itself renders per-group, matching this
/// codebase's existing "smallest slice first" precedent (see plan.md item 18).
struct EditorContainerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // Show debug toolbar whenever a session is active.
            if appState.debugState != .idle && appState.debugState != .stopped {
                DebugToolbarView()
            }

            if appState.focusedTab != nil {
                BreadcrumbBarView()
            }

            editorPanes
        }
        // Single source of truth for `documentSymbols`/breadcrumbs/Outline/Go
        // to Symbol — see `AppState.loadDocumentSymbols(for:)`'s doc comment
        // for why only ONE fetch site may exist once there are two panes.
        // Keyed on (focusedGroup, focusedTab.id) rather than just the tab id
        // so a focus change between panes with no tab switch still refetches.
        .task(id: DocumentSymbolsTaskKey(group: appState.focusedGroup, tabId: appState.focusedTab?.id)) {
            if let tab = appState.focusedTab {
                await appState.loadDocumentSymbols(for: tab)
            } else {
                appState.documentSymbols = []
            }
        }
    }

    @ViewBuilder
    private var editorPanes: some View {
        if appState.secondaryGroup != nil {
            SplitEditorPanesView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EditorPaneView(side: .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Identifies "which tab's document symbols should currently be loaded" —
/// see `EditorContainerView`'s centralized `.task(id:)` above.
private struct DocumentSymbolsTaskKey: Equatable {
    let group: EditorGroupSide
    let tabId: UUID?
}

// MARK: - SplitEditorPanesView

/// Two side-by-side editor panes with a basic draggable splitter between
/// them (plan.md item 22 point 3: "a simple fixed-ratio or basic-draggable-
/// width split is fine" — this isn't pixel-perfect resizable, just a
/// `GeometryReader`-driven width fraction clamped to a sane range).
private struct SplitEditorPanesView: View {
    @Environment(AppState.self) private var appState
    /// Primary pane's fraction of the total available width.
    @State private var splitFraction: CGFloat = 0.5

    private static let handleWidth: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let totalWidth = max(1, geo.size.width - Self.handleWidth)
            HStack(spacing: 0) {
                EditorPaneView(side: .primary)
                    .frame(width: totalWidth * splitFraction)
                SplitterHandleView(fraction: $splitFraction, totalWidth: totalWidth)
                EditorPaneView(side: .secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A narrow draggable divider between the two editor panes. Reports the
/// primary pane's fraction of `totalWidth` (clamped to 20%–80% so neither
/// pane can be dragged away entirely) back to the parent via `fraction`.
private struct SplitterHandleView: View {
    @Binding var fraction: CGFloat
    let totalWidth: CGFloat
    @State private var isHovering = false
    @State private var dragStartFraction: CGFloat?

    private let minFraction: CGFloat = 0.2
    private let maxFraction: CGFloat = 0.8

    var body: some View {
        Rectangle()
            .fill(isHovering ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
            .frame(width: 4)
            // Widen the actual hit target beyond the thin visible line
            // (dragging a literal 4pt strip is fiddly) without affecting
            // layout — `.overlay` content isn't clipped to the base view.
            .overlay(
                Color.clear
                    .frame(width: 10)
                    .contentShape(Rectangle())
            )
            .onHover { isHovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let base = dragStartFraction ?? fraction
                        dragStartFraction = base
                        guard totalWidth > 0 else { return }
                        let delta = value.translation.width / totalWidth
                        fraction = min(maxFraction, max(minFraction, base + delta))
                    }
                    .onEnded { _ in dragStartFraction = nil }
            )
    }
}

// MARK: - EditorPaneView

/// One editor group's pane: its own tab bar + active tab's editor (or the
/// Welcome screen, primary only, when nothing is open). `side` is fixed at
/// construction, so a pane never has to ask "which side am I" — its own
/// tabs/active tab/cursor writes are always unambiguous even with a second
/// pane mounted simultaneously (plan.md item 22).
private struct EditorPaneView: View {
    let side: EditorGroupSide
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(side: side)
            Divider()
            if let tab = appState.activeTab(in: side) {
                CodeEditorView(tab: tabBinding(for: tab), side: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if side == .primary {
                WelcomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Unreachable in practice: `AppState.closeTab` collapses
                // `secondaryGroup` back to `nil` (removing this pane
                // entirely) in the same call that would otherwise leave it
                // empty. Kept as a harmless fallback rather than force-
                // unwrapping — an empty second pane, not the Welcome screen
                // (which reads as "open a workspace," the wrong invitation
                // for a second editor group).
                Color(nsColor: .textBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// A binding to `side`'s active tab's content that round-trips writes
    /// through `AppState.updateTabContent` (which resolves the correct
    /// group from the tab's id) so the dirty flag is maintained correctly.
    private func tabBinding(for tab: TabModel) -> Binding<TabModel> {
        Binding {
            appState.activeTab(in: side) ?? tab
        } set: { updated in
            appState.updateTabContent(updated.id, content: updated.content)
        }
    }
}

// MARK: - CodeEditorView

/// Bridges an editor group's active-tab binding to the NSTextView-based
/// EditorView. `side` identifies which group this instance belongs to —
/// needed only for cursor-position writes (`AppState.setCursorPosition`,
/// which also updates `AppState.focusedGroup`) and to gate Find/Replace
/// (`isFocusedGroup`, see `EditorView`'s doc comment) so a still-mounted,
/// non-focused pane doesn't also react — everything else this view reads
/// (diagnostics, blame, git line changes, breakpoints, debug line) is keyed
/// by file URL, not by group, and "just works" unchanged for either pane.
struct CodeEditorView: View {
    @Binding var tab: TabModel
    var side: EditorGroupSide = .primary
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

    private var fileDiagnostics: [Diagnostic] {
        guard let url = tab.fileURL else { return [] }
        return appState.diagnostics[url] ?? []
    }

    private var fileGitLineChanges: [Int: GitLineChangeType] {
        guard let url = tab.fileURL else { return [:] }
        return appState.gitLineChanges[url] ?? [:]
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
                diagnostics:      fileDiagnostics,
                gitLineChanges:   fileGitLineChanges,
                fileURL:          tab.fileURL,
                isFocusedGroup:   appState.focusedGroup == side,
                onCursorMove: { line, col in
                    appState.setCursorPosition(tabId: tab.id, in: side, line: line, column: col)
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
            .task(id: tab.id) { await appState.refreshGitLineChanges(for: tab) }
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

// MARK: - BreadcrumbBarView

/// Thin bar above the editor showing the chain of symbols containing the
/// cursor's current line (e.g. "ClassName › methodName"), derived from
/// `AppState.breadcrumbPath` — itself computed from the same document-symbol
/// tree that feeds Go to Symbol (⇧⌘O) and the Outline panel, kept current by
/// the existing `onCursorMove`/`setCursorPosition` wiring in
/// `CodeEditorView.editorRow` (no extra plumbing needed — `breadcrumbPath`
/// recomputes whenever `focusedTab`'s `cursorLine` or `documentSymbols`
/// changes). Renders nothing when there's no path to show (no symbols loaded
/// yet, or the cursor sits outside every symbol's range). Reflects whichever
/// pane is FOCUSED (plan.md item 22), not necessarily the primary one.
/// Clicking a segment jumps to that symbol via the same `jumpTo` mechanism
/// every other cross-view navigation uses (`AppState.navigateTo`).
private struct BreadcrumbBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let path = appState.breadcrumbPath
        if !path.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(path.enumerated()), id: \.element.id) { index, symbol in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: appState.sf(9)))
                            .foregroundStyle(.tertiary)
                    }
                    Button {
                        jump(to: symbol)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: symbol.iconName)
                                .font(.system(size: appState.sf(10)))
                            Text(symbol.name)
                                .font(.system(size: appState.sf(11)))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == path.count - 1 ? Color.primary : Color.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func jump(to symbol: DocumentSymbol) {
        guard let fileURL = appState.focusedTab?.fileURL else { return }
        Task { await appState.navigateTo(DefinitionLocation(fileURL: fileURL, line: symbol.line, character: symbol.character)) }
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
