// MarkdownPreviewView.swift
// Athena — rendered-markdown preview mode for .md/.markdown tabs (plan.md item 26, "G2").
// Swift 6, strict concurrency.

import SwiftUI
import Foundation

// MARK: - MarkdownRenderer

/// Converts markdown source into a rich `AttributedString` and groups it into
/// block-level chunks, using Foundation's built-in parser — no new dependency
/// (per CLAUDE.md's "keep dependencies minimal"). Both functions are pure
/// (no I/O, no SwiftUI) so they're covered directly by `AthenaTests` without
/// standing up any view.
enum MarkdownRenderer {
    /// Parses `markdown` with the full CommonMark-ish syntax (headers, bold,
    /// italic, links, lists, code spans, fenced code blocks, block quotes).
    /// Never throws outward: a source string the parser can't fully make
    /// sense of still renders whatever it could
    /// (`.returnPartiallyParsedIfPossible`) rather than showing nothing, and
    /// the extremely rare hard failure falls back to inline-only parsing so
    /// there's always *something* to preview.
    static func render(_ markdown: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        if let parsed = try? AttributedString(markdown: markdown, options: options) {
            return parsed
        }
        return (try? AttributedString(markdown: markdown)) ?? AttributedString(markdown)
    }

    /// Groups a parsed markdown `AttributedString` into block-level chunks
    /// suitable for one-`Text`-per-block rendering. Headers/lists/code
    /// blocks/quotes each need distinct visual treatment that SwiftUI doesn't
    /// apply automatically from `PresentationIntent` alone — inline
    /// emphasis/strong-emphasis/code-span/link attributes DO render
    /// automatically when a `Text` is built from an `AttributedString`
    /// (or subrange), so those are left untouched here and just carried
    /// through on `MarkdownBlock.text`.
    ///
    /// Consecutive runs are merged into one block when they share the same
    /// innermost `PresentationIntent` identity — Foundation assigns every
    /// paragraph/heading/code block/list item its own unique `identity`, so
    /// a single sentence with bold/italic/code spans (multiple runs) still
    /// collapses into one block rather than fragmenting per run.
    static func blocks(in attributed: AttributedString) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        for run in attributed.runs {
            let intents = run.presentationIntent?.components ?? []
            let identity = intents.first?.identity ?? -1
            let kind = blockKind(for: intents)
            if var last = result.last, last.id == identity, last.kind == kind {
                last.text += AttributedString(attributed[run.range])
                result[result.count - 1] = last
            } else {
                result.append(
                    MarkdownBlock(id: identity, kind: kind, text: AttributedString(attributed[run.range]))
                )
            }
        }
        return result
    }

    /// Classifies a run's intent stack into the one `MarkdownBlock.Kind` that
    /// drives its visual treatment, preferring the innermost meaningful
    /// intent (header/codeBlock/blockQuote/listItem) over the generic
    /// `paragraph` wrapper those can all still carry.
    private static func blockKind(for intents: [PresentationIntent.IntentType]) -> MarkdownBlock.Kind {
        for intent in intents {
            switch intent.kind {
            case .header(let level):
                return .heading(level: level)
            case .codeBlock(let languageHint):
                return .codeBlock(language: languageHint)
            case .blockQuote:
                return .blockQuote
            case .listItem(let ordinal):
                let ordered = intents.contains {
                    if case .orderedList = $0.kind { return true }
                    return false
                }
                return .listItem(ordinal: ordinal, ordered: ordered)
            default:
                continue
            }
        }
        return .paragraph
    }
}

// MARK: - MarkdownBlock

/// One visually-distinct chunk of parsed markdown — a paragraph, heading,
/// code block, block quote, or list item — as produced by
/// `MarkdownRenderer.blocks(in:)`.
struct MarkdownBlock: Identifiable, Sendable {
    enum Kind: Sendable, Equatable {
        case heading(level: Int)
        case codeBlock(language: String?)
        case blockQuote
        case listItem(ordinal: Int?, ordered: Bool)
        case paragraph
    }

    let id: Int
    let kind: Kind
    var text: AttributedString
}

// MARK: - MarkdownPreviewView

/// Rendered "Preview" side of a markdown tab's Source/Preview toggle
/// (`CodeEditorView`'s `markdownToolbar`). Re-renders once on appearing —
/// not live-as-you-type — per the task's accepted simpler scope; switching
/// back to Source and re-toggling to Preview re-parses the latest content.
struct MarkdownPreviewView: View {
    @Environment(AppState.self) private var appState
    let markdown: String

    private var blocks: [MarkdownBlock] {
        MarkdownRenderer.blocks(in: MarkdownRenderer.render(markdown))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: appState.sf(10)) {
                ForEach(blocks) { block in
                    blockView(block)
                }
            }
            // Base body size for paragraphs/quotes/list items; headings and
            // code blocks override it below. Reading `appState.sf` here also
            // re-renders the preview whenever the UI zoom changes.
            .font(.system(size: appState.sf(13)))
            .padding(appState.sf(20))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(headingFont(level))
                .fontWeight(.bold)
                .padding(.top, appState.sf(level <= 2 ? 6 : 2))

        case .codeBlock:
            Text(block.text)
                .font(.system(size: appState.sf(13), design: .monospaced))
                .textSelection(.enabled)
                .padding(appState.sf(10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06))
                .cornerRadius(appState.sf(6))

        case .blockQuote:
            HStack(alignment: .top, spacing: appState.sf(8)) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: appState.sf(3))
                Text(block.text)
                    .italic()
                    .foregroundStyle(.secondary)
            }

        case .listItem(let ordinal, let ordered):
            HStack(alignment: .top, spacing: appState.sf(6)) {
                Text(ordered ? "\(ordinal ?? 1)." : "•")
                    .foregroundStyle(.secondary)
                Text(block.text)
            }
            .padding(.leading, appState.sf(8))

        case .paragraph:
            Text(block.text)
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .system(size: appState.sf(22))
        case 2:  return .system(size: appState.sf(19))
        case 3:  return .system(size: appState.sf(16))
        default: return .system(size: appState.sf(14))
        }
    }
}
