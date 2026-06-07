import type { Monaco } from '@monaco-editor/react'
import type { languages } from 'monaco-editor'
import { lspClient } from './lspClient'
import { useWorkspaceStore } from '../../store/workspace'

type LspPos = { line: number; character: number }
type LspRange = { start: LspPos; end: LspPos }
type LspLocation = { uri: string; range: LspRange }
type LspMarkup = string | { kind: string; value: string }
type LspMarkedString = string | { language: string; value: string }

type LspCompletionItem = {
  label: string
  kind?: number
  detail?: string
  documentation?: LspMarkup
  insertText?: string
  insertTextFormat?: number
  textEdit?: { range: LspRange; newText: string }
  additionalTextEdits?: Array<{ range: LspRange; newText: string }>
  sortText?: string
  filterText?: string
  deprecated?: boolean
  preselect?: boolean
}

type LspHover = {
  contents: LspMarkup | LspMarkedString | LspMarkup[] | LspMarkedString[]
  range?: LspRange
}

type LspSignatureHelp = {
  signatures: Array<{
    label: string
    documentation?: LspMarkup
    parameters?: Array<{ label: string | [number, number]; documentation?: LspMarkup }>
  }>
  activeSignature?: number
  activeParameter?: number
}

type LspDocSym = {
  name: string
  detail?: string
  kind: number
  range: LspRange
  selectionRange: LspRange
  children?: LspDocSym[]
}

// LSP CompletionItemKind (1-based) → Monaco CompletionItemKind (0-based raw number)
const COMP_KIND: Record<number, number> = {
  1: 18,
  2: 0,
  3: 1,
  4: 2,
  5: 3,
  6: 4,
  7: 5,
  8: 7,
  9: 8,
  10: 9,
  11: 12,
  12: 13,
  13: 15,
  14: 17,
  15: 27,
  16: 19,
  17: 20,
  18: 21,
  19: 23,
  20: 16,
  21: 14,
  22: 6,
  23: 10,
  24: 11,
  25: 24
}

// LSP SymbolKind is 1-based, Monaco's is 0-based (same names)
const symKind = (k: number): number => Math.max(0, k - 1)

const LSP_LANGS = ['typescript', 'javascript']

function lspLangId(monacoLang: string, uri: string): string {
  if (monacoLang === 'typescript' && uri.endsWith('.tsx')) return 'typescriptreact'
  if (monacoLang === 'javascript' && (uri.endsWith('.jsx') || uri.endsWith('.mjsx')))
    return 'javascriptreact'
  return monacoLang
}

function mRange(r: LspRange, monaco: Monaco): import('monaco-editor').Range {
  return new monaco.Range(
    r.start.line + 1,
    r.start.character + 1,
    r.end.line + 1,
    r.end.character + 1
  )
}

function toLsp(lineNumber: number, column: number): LspPos {
  return { line: lineNumber - 1, character: column - 1 }
}

function markerSeverity(s: number | undefined, monaco: Monaco): number {
  if (s === 1) return monaco.MarkerSeverity.Error
  if (s === 2) return monaco.MarkerSeverity.Warning
  if (s === 3) return monaco.MarkerSeverity.Info
  return monaco.MarkerSeverity.Hint
}

function markupValue(m: LspMarkup): string {
  return typeof m === 'string' ? m : m.value
}

function normalizeHoverContents(
  raw: LspHover['contents']
): { value: string; isTrusted?: boolean }[] {
  const items = Array.isArray(raw) ? raw : [raw]
  return items
    .map((c): { value: string } => {
      if (typeof c === 'string') return { value: c }
      if ('language' in c) return { value: `\`\`\`${c.language}\n${c.value}\n\`\`\`` }
      return { value: (c as { value: string }).value }
    })
    .filter((c) => c.value.trim())
}

function convertDocSym(sym: LspDocSym, monaco: Monaco): languages.DocumentSymbol {
  return {
    name: sym.name,
    detail: sym.detail ?? '',
    kind: symKind(sym.kind) as languages.SymbolKind,
    tags: [],
    range: mRange(sym.range, monaco),
    selectionRange: mRange(sym.selectionRange, monaco),
    children: sym.children?.map((c) => convertDocSym(c, monaco)) ?? []
  }
}

export function registerLspProviders(monaco: Monaco): void {
  // Document sync — hook model lifecycle
  monaco.editor.onDidCreateModel((model) => {
    const langId = model.getLanguageId()
    if (!LSP_LANGS.includes(langId)) return

    // Lazy LSP start: spawn server on first TS/JS file open.
    void useWorkspaceStore.getState().ensureLsp()

    const uri = model.uri.toString()

    if (lspClient.ready) {
      lspClient.openDocument(uri, lspLangId(langId, uri), model.getVersionId(), model.getValue())
    }

    const changeSub = model.onDidChangeContent(() => {
      if (lspClient.ready) lspClient.changeDocument(uri, model.getVersionId(), model.getValue())
    })

    model.onWillDispose(() => {
      changeSub.dispose()
      if (lspClient.ready) lspClient.closeDocument(uri)
      monaco.editor.setModelMarkers(model, 'lsp', [])
    })
  })

  // Sync all open models once LSP is ready
  lspClient.onReady(() => {
    for (const model of monaco.editor.getModels()) {
      const langId = model.getLanguageId()
      if (!LSP_LANGS.includes(langId)) continue
      const mUri = model.uri.toString()
      lspClient.openDocument(mUri, lspLangId(langId, mUri), model.getVersionId(), model.getValue())
    }
  })

  // Semantic diagnostics
  lspClient.onNotification('textDocument/publishDiagnostics', (params) => {
    const { uri, diagnostics } = params as {
      uri: string
      diagnostics: Array<{
        range: LspRange
        severity?: number
        message: string
        source?: string
        code?: string | number
      }>
    }
    const model = monaco.editor.getModel(monaco.Uri.parse(uri))
    if (!model) return
    monaco.editor.setModelMarkers(
      model,
      'lsp',
      diagnostics.map((d) => ({
        severity: markerSeverity(d.severity, monaco),
        startLineNumber: d.range.start.line + 1,
        startColumn: d.range.start.character + 1,
        endLineNumber: d.range.end.line + 1,
        endColumn: d.range.end.character + 1,
        message: d.message,
        source: d.source,
        code: d.code !== undefined ? String(d.code) : undefined
      }))
    )
  })

  // Completion
  for (const lang of LSP_LANGS) {
    monaco.languages.registerCompletionItemProvider(lang, {
      triggerCharacters: ['.', '"', "'", '`', '/', '@', '<', '#'],

      async provideCompletionItems(model, position) {
        if (!lspClient.ready) return null
        const raw = await lspClient.request<
          { isIncomplete: boolean; items: LspCompletionItem[] } | LspCompletionItem[] | null
        >('textDocument/completion', {
          textDocument: { uri: model.uri.toString() },
          position: toLsp(position.lineNumber, position.column),
          context: { triggerKind: 1 }
        })
        if (!raw) return null

        const items: LspCompletionItem[] = Array.isArray(raw) ? raw : (raw.items ?? [])
        const incomplete = !Array.isArray(raw) && (raw.isIncomplete ?? false)
        const word = model.getWordUntilPosition(position)
        const defaultRange = new monaco.Range(
          position.lineNumber,
          word.startColumn,
          position.lineNumber,
          word.endColumn
        )

        return {
          incomplete,
          suggestions: items.map((item) => {
            const suggestion: languages.CompletionItem & { _lsp?: LspCompletionItem } = {
              label: item.label,
              kind: COMP_KIND[item.kind ?? 1] ?? 18,
              detail: item.detail,
              documentation: item.documentation
                ? { value: markupValue(item.documentation) }
                : undefined,
              insertText: item.textEdit?.newText ?? item.insertText ?? item.label,
              insertTextRules:
                item.insertTextFormat === 2
                  ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet
                  : monaco.languages.CompletionItemInsertTextRule.None,
              range: item.textEdit ? mRange(item.textEdit.range, monaco) : defaultRange,
              sortText: item.sortText,
              filterText: item.filterText,
              tags: item.deprecated ? [1] : undefined,
              preselect: item.preselect,
              additionalTextEdits: item.additionalTextEdits?.map((e) => ({
                range: mRange(e.range, monaco),
                text: e.newText
              }))
            }
            suggestion._lsp = item
            return suggestion
          })
        }
      },

      async resolveCompletionItem(item) {
        const lspItem = (item as languages.CompletionItem & { _lsp?: LspCompletionItem })._lsp
        if (!lspItem || !lspClient.ready) return item
        try {
          const resolved = await lspClient.request<LspCompletionItem>(
            'completionItem/resolve',
            lspItem
          )
          if (resolved.documentation)
            item.documentation = { value: markupValue(resolved.documentation) }
          if (resolved.detail) item.detail = resolved.detail
          if (resolved.additionalTextEdits?.length) {
            item.additionalTextEdits = resolved.additionalTextEdits.map((e) => ({
              range: mRange(e.range, monaco),
              text: e.newText
            }))
          }
        } catch {
          // best-effort
        }
        return item
      }
    })
  }

  // Hover
  for (const lang of LSP_LANGS) {
    monaco.languages.registerHoverProvider(lang, {
      async provideHover(model, position) {
        if (!lspClient.ready) return null
        const result = await lspClient.request<LspHover | null>('textDocument/hover', {
          textDocument: { uri: model.uri.toString() },
          position: toLsp(position.lineNumber, position.column)
        })
        if (!result) return null
        const contents = normalizeHoverContents(result.contents)
        if (!contents.length) return null
        return {
          contents,
          range: result.range ? mRange(result.range, monaco) : undefined
        }
      }
    })
  }

  // Signature Help
  for (const lang of LSP_LANGS) {
    monaco.languages.registerSignatureHelpProvider(lang, {
      signatureHelpTriggerCharacters: ['(', ',', '<'],

      async provideSignatureHelp(model, position) {
        if (!lspClient.ready) return null
        const result = await lspClient.request<LspSignatureHelp | null>(
          'textDocument/signatureHelp',
          {
            textDocument: { uri: model.uri.toString() },
            position: toLsp(position.lineNumber, position.column)
          }
        )
        if (!result || !result.signatures.length) return null
        return {
          value: {
            signatures: result.signatures.map((sig) => ({
              label: sig.label,
              documentation: sig.documentation
                ? { value: markupValue(sig.documentation) }
                : undefined,
              parameters: (sig.parameters ?? []).map((p) => ({
                label: p.label,
                documentation: p.documentation ? { value: markupValue(p.documentation) } : undefined
              }))
            })),
            activeSignature: result.activeSignature ?? 0,
            activeParameter: result.activeParameter ?? 0
          },
          dispose: () => {}
        }
      }
    })
  }

  // Definition (cross-file, symbol-aware)
  for (const lang of LSP_LANGS) {
    monaco.languages.registerDefinitionProvider(lang, {
      async provideDefinition(model, position) {
        if (!lspClient.ready) return null
        const result = await lspClient.request<LspLocation | LspLocation[] | null>(
          'textDocument/definition',
          {
            textDocument: { uri: model.uri.toString() },
            position: toLsp(position.lineNumber, position.column)
          }
        )
        if (!result) return null
        return (Array.isArray(result) ? result : [result]).map((loc) => ({
          uri: monaco.Uri.parse(loc.uri),
          range: mRange(loc.range, monaco)
        }))
      }
    })
  }

  // References
  for (const lang of LSP_LANGS) {
    monaco.languages.registerReferenceProvider(lang, {
      async provideReferences(model, position, ctx) {
        if (!lspClient.ready) return null
        const result = await lspClient.request<LspLocation[] | null>('textDocument/references', {
          textDocument: { uri: model.uri.toString() },
          position: toLsp(position.lineNumber, position.column),
          context: { includeDeclaration: ctx.includeDeclaration }
        })
        if (!result) return null
        return result.map((loc) => ({
          uri: monaco.Uri.parse(loc.uri),
          range: mRange(loc.range, monaco)
        }))
      }
    })
  }

  // Implementation
  for (const lang of LSP_LANGS) {
    monaco.languages.registerImplementationProvider(lang, {
      async provideImplementation(model, position) {
        if (!lspClient.ready) return null
        const result = await lspClient.request<LspLocation | LspLocation[] | null>(
          'textDocument/implementation',
          {
            textDocument: { uri: model.uri.toString() },
            position: toLsp(position.lineNumber, position.column)
          }
        )
        if (!result) return null
        return (Array.isArray(result) ? result : [result]).map((loc) => ({
          uri: monaco.Uri.parse(loc.uri),
          range: mRange(loc.range, monaco)
        }))
      }
    })
  }

  // Document Symbols
  for (const lang of LSP_LANGS) {
    monaco.languages.registerDocumentSymbolProvider(lang, {
      displayName: 'LSP',
      async provideDocumentSymbols(model) {
        if (!lspClient.ready) return null
        const result = await lspClient.request<LspDocSym[] | null>('textDocument/documentSymbol', {
          textDocument: { uri: model.uri.toString() }
        })
        if (!result) return null
        return result.map((sym) => convertDocSym(sym, monaco))
      }
    })
  }
}
