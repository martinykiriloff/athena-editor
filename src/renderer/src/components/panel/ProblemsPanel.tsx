import { AlertCircle, AlertTriangle } from 'lucide-react'
import { useProblemsStore } from '../../store/problems'
import { useEditorStore } from '../../store/editor'

function baseName(p: string): string {
  return p.split(/[/\\]/).pop() ?? p
}

function ProblemsPanel(): React.JSX.Element {
  const byFile = useProblemsStore((s) => s.byFile)
  const openFile = useEditorStore((s) => s.openFile)
  const entries = Object.entries(byFile)

  if (entries.length === 0) {
    return <div className="panel-empty">No problems detected.</div>
  }

  return (
    <div className="problems">
      {entries.map(([path, messages]) => (
        <div key={path} className="problems-file">
          <div className="problems-file-name">{baseName(path)}</div>
          {messages.map((m, i) => (
            <div
              key={i}
              className="problem-row"
              onClick={() => void openFile(path, baseName(path))}
            >
              {m.severity === 2 ? (
                <AlertCircle size={13} className="sev-error" />
              ) : (
                <AlertTriangle size={13} className="sev-warn" />
              )}
              <span className="problem-msg">{m.message}</span>
              <span className="problem-loc">
                [{m.line}:{m.column}] {m.ruleId ?? ''}
              </span>
            </div>
          ))}
        </div>
      ))}
    </div>
  )
}

export default ProblemsPanel
