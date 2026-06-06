import { useEffect } from 'react'
import { CheckCircle2, CircleDashed, Play, RotateCw, XCircle } from 'lucide-react'
import { useJestStore } from '../../store/jest'
import { useLayoutStore } from '../../store/layout'

function baseName(p: string): string {
  return p.split(/[/\\]/).pop() ?? p
}

function statusIcon(status: string): React.JSX.Element {
  if (status === 'passed') return <CheckCircle2 size={13} className="sev-pass" />
  if (status === 'failed') return <XCircle size={13} className="sev-error" />
  return <CircleDashed size={13} className="sev-warn" />
}

function TestExplorer(): React.JSX.Element {
  const { report, running, error, run, subscribe } = useJestStore()
  const openPanel = useLayoutStore((s) => s.openPanel)

  useEffect(() => subscribe(), [subscribe])

  const runAll = (): void => {
    openPanel('tests')
    void run()
  }

  return (
    <div className="tests">
      <div className="tests-toolbar">
        <button onClick={runAll} disabled={running}>
          {running ? <RotateCw size={13} className="spin" /> : <Play size={13} />} Run All
        </button>
        {report && (
          <span className="tests-summary">
            {report.numPassed}✓ {report.numFailed}✗
          </span>
        )}
      </div>

      {error && <div className="tests-error">{error}</div>}

      {report?.files.map((f) => (
        <div key={f.name} className="tests-file">
          <div className="tests-file-head" onClick={() => void run(f.name)} title="Run this file">
            {statusIcon(f.status)}
            <span>{baseName(f.name)}</span>
          </div>
          {f.tests.map((t, i) => (
            <div
              key={i}
              className="tests-case"
              onClick={() => openPanel('tests')}
              title={t.failureMessages.join('\n')}
            >
              {statusIcon(t.status)}
              <span>{t.title}</span>
            </div>
          ))}
        </div>
      ))}

      {!report && !running && !error && (
        <div className="panel-empty">Run tests to see results.</div>
      )}
    </div>
  )
}

export default TestExplorer
