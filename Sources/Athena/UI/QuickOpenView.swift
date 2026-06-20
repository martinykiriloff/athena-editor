// QuickOpenView.swift
// Athena — ⌘P file-search palette (VS Code parity).
// Swift 6, strict concurrency.

import SwiftUI
import AppKit

// MARK: - QuickOpenView

struct QuickOpenView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0

    private var results: [FileNode] {
        let all = appState.allFiles
        guard !query.isEmpty else {
            return Array(all.prefix(200))
        }
        let q = query.lowercased()
        let filtered = all.filter { $0.url.path.lowercased().contains(q) }
        return filtered.sorted { a, b in
            let aName = a.name.lowercased().hasPrefix(q)
            let bName = b.name.lowercased().hasPrefix(q)
            if aName != bName { return aName }
            let aContains = a.name.lowercased().contains(q)
            let bContains = b.name.lowercased().contains(q)
            if aContains != bContains { return aContains }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop — tap to dismiss
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { close() }

            // Palette card
            VStack(spacing: 0) {
                QuickOpenSearchField(
                    placeholder: "Go to file…",
                    text: $query,
                    onArrowUp:   { move(-1) },
                    onArrowDown: { move(1) },
                    onReturn:    { confirmSelection() },
                    onEscape:    { close() }
                )
                .frame(height: 44)
                .padding(.horizontal, 12)

                if !results.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(results.prefix(200).enumerated()), id: \.element.id) { i, file in
                                    QuickOpenRow(
                                        file: file,
                                        query: query,
                                        isSelected: i == selectedIndex,
                                        workspaceURL: appState.workspace?.rootURL
                                    )
                                    .id(i)
                                    .onTapGesture { open(file) }
                                }
                            }
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: selectedIndex) { _, idx in
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                } else if !query.isEmpty {
                    Divider()
                    Text("No results for \"\(query)\"")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 12))
                        .padding(20)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 12)
            .frame(width: 580)
            .padding(.top, 80)
        }
        .onChange(of: query) { selectedIndex = 0 }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let count = min(results.count, 200)
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func confirmSelection() {
        guard selectedIndex < results.count else { return }
        open(results[selectedIndex])
    }

    private func open(_ file: FileNode) {
        Task { await appState.openFile(file.url) }
        close()
    }

    private func close() {
        appState.showQuickOpen = false
    }
}

// MARK: - Row

private struct QuickOpenRow: View {
    let file: FileNode
    let query: String
    let isSelected: Bool
    let workspaceURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? .white : .primary)
                    .lineLimit(1)

                if let rel = relativePath {
                    Text(rel)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.65) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
    }

    private var relativePath: String? {
        guard let root = workspaceURL else { return nil }
        let dir = file.url.deletingLastPathComponent().path
        guard dir.hasPrefix(root.path) else { return nil }
        let rel = String(dir.dropFirst(root.path.count))
        let trimmed = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - NSTextField search field (intercepts ↑ ↓ ↵ ⎋ before AppKit eats them)

private struct QuickOpenSearchField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onArrowUp:   () -> Void
    var onArrowDown: () -> Void
    var onReturn:    () -> Void
    var onEscape:    () -> Void

    func makeNSView(context: Context) -> InterceptingTextField {
        let field = InterceptingTextField()
        field.delegate          = context.coordinator
        field.placeholderString = placeholder
        field.isBezeled         = false
        field.drawsBackground   = false
        field.font              = .systemFont(ofSize: 16)
        field.focusRingType     = .none
        field.lineBreakMode     = .byTruncatingTail
        field.cell?.isScrollable = true
        field.onArrowUp   = onArrowUp
        field.onArrowDown = onArrowDown
        field.onReturn    = onReturn
        field.onEscape    = onEscape
        // Grab keyboard focus after the view is in the window hierarchy.
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: InterceptingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onArrowUp   = onArrowUp
        nsView.onArrowDown = onArrowDown
        nsView.onReturn    = onReturn
        nsView.onEscape    = onEscape
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuickOpenSearchField
        init(_ parent: QuickOpenSearchField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

// MARK: - InterceptingTextField

final class InterceptingTextField: NSTextField {
    // nonisolated(unsafe): these callbacks are always invoked on the main thread
    // (NSEvent delivery is always on main), but Swift 6 can't verify that
    // statically when they're stored as plain closures.
    nonisolated(unsafe) var onArrowUp:   (() -> Void)?
    nonisolated(unsafe) var onArrowDown: (() -> Void)?
    nonisolated(unsafe) var onReturn:    (() -> Void)?
    nonisolated(unsafe) var onEscape:    (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: MainActor.assumeIsolated { onArrowDown?() }  // ↓
        case 126: MainActor.assumeIsolated { onArrowUp?() }    // ↑
        case 36:  MainActor.assumeIsolated { onReturn?() }     // ↵
        case 53:  MainActor.assumeIsolated { onEscape?() }     // ⎋
        default:  super.keyDown(with: event)
        }
    }
}
