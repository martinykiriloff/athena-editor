import type { Monaco } from '@monaco-editor/react'
import type { editor } from 'monaco-editor'

export const EDITOR_FONT = "'Fira Code Retina', 'Fira Code', Menlo, Monaco, monospace"
export const EDITOR_FONT_SIZE = 16

// Shared Monaco options for the code editor and diff editor.
export const baseEditorOptions: editor.IEditorOptions = {
  fontFamily: EDITOR_FONT,
  fontSize: EDITOR_FONT_SIZE,
  fontLigatures: true,
  renderWhitespace: 'all',
  minimap: { enabled: true, side: 'right' },
  automaticLayout: true,
  scrollBeyondLastLine: false
}

// JetBrains Darcula approximation.
const darcula: editor.IStandaloneThemeData = {
  base: 'vs-dark',
  inherit: true,
  rules: [
    { token: '', foreground: 'A9B7C6', background: '2B2B2B' },
    { token: 'comment', foreground: '808080', fontStyle: 'italic' },
    { token: 'keyword', foreground: 'CC7832' },
    { token: 'keyword.control', foreground: 'CC7832' },
    { token: 'operator', foreground: 'A9B7C6' },
    { token: 'delimiter', foreground: 'A9B7C6' },
    { token: 'string', foreground: '6A8759' },
    { token: 'string.escape', foreground: 'CC7832' },
    { token: 'regexp', foreground: '6A8759' },
    { token: 'number', foreground: '6897BB' },
    { token: 'constant', foreground: '9876AA' },
    { token: 'constant.language', foreground: 'CC7832' },
    { token: 'variable', foreground: 'A9B7C6' },
    { token: 'variable.predefined', foreground: '9876AA' },
    { token: 'type', foreground: 'A9B7C6' },
    { token: 'type.identifier', foreground: 'A9B7C6' },
    { token: 'class', foreground: 'A9B7C6' },
    { token: 'function', foreground: 'FFC66D' },
    { token: 'identifier', foreground: 'A9B7C6' },
    { token: 'tag', foreground: 'E8BF6A' },
    { token: 'attribute.name', foreground: 'BABABA' },
    { token: 'attribute.value', foreground: '6A8759' },
    { token: 'metatag', foreground: 'BBB529' },
    { token: 'annotation', foreground: 'BBB529' },
    { token: 'key', foreground: 'CC7832' }
  ],
  colors: {
    'editor.background': '#2B2B2B',
    'editor.foreground': '#A9B7C6',
    'editorLineNumber.foreground': '#606366',
    'editorLineNumber.activeForeground': '#A4A3A3',
    'editor.selectionBackground': '#214283',
    'editor.inactiveSelectionBackground': '#21428360',
    'editor.lineHighlightBackground': '#323232',
    'editorCursor.foreground': '#BBBBBB',
    'editorWhitespace.foreground': '#4B4B4B',
    'editorIndentGuide.background': '#404040',
    'editorIndentGuide.activeBackground': '#5A5A5A',
    'editorGutter.background': '#2B2B2B',
    'editorError.foreground': '#BC3F3C',
    'editorWarning.foreground': '#BBB529',
    'minimap.background': '#2B2B2B'
  }
}

export const DARCULA = 'darcula'

export function defineDarcula(monaco: Monaco): void {
  monaco.editor.defineTheme(DARCULA, darcula)
}
