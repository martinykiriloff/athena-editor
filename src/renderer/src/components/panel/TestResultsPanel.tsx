import { useJestStore } from '../../store/jest'

function TestResultsPanel(): React.JSX.Element {
  const { report, running, error } = useJestStore()

  if (running) return <div className="panel-empty">Running tests…</div>
  if (error) return <pre className="test-output error">{error}</pre>
  if (!report) return <div className="panel-empty">No test run yet.</div>

  const failures = report.files.flatMap((f) =>
    f.tests.filter((t) => t.status === 'failed').map((t) => ({ file: f.name, t }))
  )

  return (
    <div className="test-output">
      <div className={`test-summary ${report.success ? 'pass' : 'fail'}`}>
        {report.numPassed} passed · {report.numFailed} failed
      </div>
      {failures.map((f, i) => (
        <div key={i} className="test-failure">
          <div className="test-failure-title">
            {f.t.ancestors.join(' › ')} › {f.t.title}
          </div>
          <pre>{f.t.failureMessages.join('\n\n')}</pre>
        </div>
      ))}
    </div>
  )
}

export default TestResultsPanel
