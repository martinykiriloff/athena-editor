import { useEffect, useRef } from 'react'
import Editor, { type Monaco, type OnMount } from '@monaco-editor/react'
import type { editor } from 'monaco-editor'
import { useEditorStore } from '../../store/editor'
import { useProblemsStore } from '../../store/problems'
import { languageForPath } from './language'
import { DARCULA, baseEditorOptions } from './theme'
import type { LintMessage } from '../../types'

function MonacoEditor(): React.JSX.Element {
  const tabs = useEditorStore((s) => s.tabs)
  const activePath = useEditorStore((s) => s.activePath)
  const updateContent = useEditorStore((s) => s.updateContent)
  const save = useEditorStore((s) => s.save)
  const setProblems = useProblemsStore((s) => s.setForFile)
  const monacoRef = useRef<Monaco | null>(null)
  const editorRef = useRef<editor.IStandaloneCodeEditor | null>(null)
  const active = tabs.find((t) => t.path === activePath)

  const onMount: OnMount = (ed, monaco) => {
    monacoRef.current = monaco
    editorRef.current = ed
    ed.getModel()?.updateOptions({ tabSize: 2 })
    ed.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, () => {
      const path = useEditorStore.getState().activePath
      if (path) void save(path)
    })
  }

  // Lint the active file (debounced) and publish markers + problems.
  useEffect(() => {
    if (!active) return
    const path = active.path
    const content = active.content
    const handle = setTimeout(async () => {
      const messages = (await window.api.eslint.lint(path, content)) as LintMessage[]
      setProblems(path, messages)
      const monaco = monacoRef.current
      const model = editorRef.current?.getModel()
      if (monaco && model) {
        monaco.editor.setModelMarkers(
          model,
          'eslint',
          messages.map((m) => ({
            severity: m.severity === 2 ? 8 : 4, // Error : Warning
            message: `${m.message}${m.ruleId ? ` (${m.ruleId})` : ''}`,
            startLineNumber: m.line,
            startColumn: m.column,
            endLineNumber: m.endLine ?? m.line,
            endColumn: m.endColumn ?? m.column + 1
          }))
        )
      }
    }, 500)
    return () => clearTimeout(handle)
  }, [active, setProblems])

  if (!active) {
    return (
      <div className="editor-empty">
        <p>Athena</p>
        <span>Open a file from the explorer, or ask Claude to get started.</span>
      </div>
    )
  }

  return (
    <Editor
      key={active.path}
      theme={DARCULA}
      path={active.path}
      language={languageForPath(active.path)}
      value={active.content}
      onChange={(value) => updateContent(active.path, value ?? '')}
      onMount={onMount}
      options={baseEditorOptions}
    />
  )
}

export default MonacoEditor
