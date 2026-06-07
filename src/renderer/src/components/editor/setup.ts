import type { Monaco } from '@monaco-editor/react'
import { useEditorStore } from '../../store/editor'
import { registerLspProviders } from './lspProviders'

// LSP handles TS/JS — keep import-resolver only for stylesheet/markup languages.
const IMPORT_LANGS = ['html', 'css', 'scss', 'less']

// Regexes whose first capture group is the module specifier.
const SPEC_PATTERNS: RegExp[] = [
  /\b(?:import|export)\b[^'"]*?['"]([^'"]+)['"]/g,
  /\brequire\(\s*['"]([^'"]+)['"]\s*\)/g,
  /\bfrom\s+['"]([^'"]+)['"]/g,
  /@import\s+(?:url\(\s*)?['"]([^'"]+)['"]/g,
  /\burl\(\s*['"]?([^'")]+)['"]?\s*\)/g
]

interface SpecHit {
  specifier: string
  startCol: number // 1-based
  endCol: number // 1-based, exclusive
}

/** If the cursor sits inside a module specifier on this line, return it. */
function specifierAt(line: string, column: number): SpecHit | null {
  for (const re of SPEC_PATTERNS) {
    re.lastIndex = 0
    let m: RegExpExecArray | null
    while ((m = re.exec(line)) !== null) {
      const spec = m[1]
      const idx = m.index + m[0].indexOf(spec)
      const startCol = idx + 1
      const endCol = startCol + spec.length
      if (column >= startCol && column <= endCol) {
        return { specifier: spec, startCol, endCol }
      }
    }
  }
  return null
}

function basename(p: string): string {
  return p.split(/[/\\]/).pop() ?? p
}

export function setupLanguages(monaco: Monaco): void {
  const ts = monaco.languages.typescript

  const compilerOptions = {
    target: ts.ScriptTarget.ESNext,
    allowJs: true,
    checkJs: false,
    allowNonTsExtensions: true,
    moduleResolution: ts.ModuleResolutionKind.NodeJs,
    module: ts.ModuleKind.ESNext,
    jsx: ts.JsxEmit.ReactJSX,
    esModuleInterop: true,
    allowSyntheticDefaultImports: true,
    skipLibCheck: true,
    lib: ['esnext', 'dom', 'dom.iterable']
  }
  ts.typescriptDefaults.setCompilerOptions(compilerOptions)
  ts.javascriptDefaults.setCompilerOptions(compilerOptions)

  ts.typescriptDefaults.setEagerModelSync(true)
  ts.javascriptDefaults.setEagerModelSync(true)

  // Keep rich hovers/quick-info, but suppress cross-file "cannot find module"
  // noise — ESLint already provides our diagnostics, and the worker can't see
  // the whole project.
  const diagnostics = { noSemanticValidation: true, noSyntaxValidation: false }
  ts.typescriptDefaults.setDiagnosticsOptions(diagnostics)
  ts.javascriptDefaults.setDiagnosticsOptions(diagnostics)

  // ---- Click-to-open on imports: resolve the specifier to a real file. ----
  const definitionProvider: import('monaco-editor').languages.DefinitionProvider = {
    async provideDefinition(model, position) {
      const line = model.getLineContent(position.lineNumber)
      const hit = specifierAt(line, position.column)
      if (!hit) return null
      const fromFile = model.uri.fsPath || model.uri.path
      const target = await window.api.fs.resolveImport(fromFile, hit.specifier)
      if (!target) return null
      return {
        uri: monaco.Uri.file(target),
        range: new monaco.Range(1, 1, 1, 1)
      }
    }
  }
  for (const lang of IMPORT_LANGS) {
    monaco.languages.registerDefinitionProvider(lang, definitionProvider)
  }

  // ---- Hover over an import shows where it resolves. ----
  const hoverProvider: import('monaco-editor').languages.HoverProvider = {
    async provideHover(model, position) {
      const line = model.getLineContent(position.lineNumber)
      const hit = specifierAt(line, position.column)
      if (!hit) return null
      const fromFile = model.uri.fsPath || model.uri.path
      const target = await window.api.fs.resolveImport(fromFile, hit.specifier)
      const value = target
        ? `**→ ${basename(target)}**\n\n\`${target}\`\n\n_Ctrl/Cmd+click to open_`
        : `_Could not resolve \`${hit.specifier}\`_`
      return {
        range: new monaco.Range(position.lineNumber, hit.startCol, position.lineNumber, hit.endCol),
        contents: [{ value }]
      }
    }
  }
  for (const lang of IMPORT_LANGS) {
    monaco.languages.registerHoverProvider(lang, hoverProvider)
  }

  // ---- Open resolved files in our tab system (go-to-definition target). ----
  monaco.editor.registerEditorOpener({
    openCodeEditor(_source, resource) {
      const path = resource.fsPath || resource.path
      if (!path) return false
      void useEditorStore.getState().openFile(path, basename(path))
      return true
    }
  })

  // Register LSP-backed providers for TypeScript / JavaScript.
  registerLspProviders(monaco)
}
