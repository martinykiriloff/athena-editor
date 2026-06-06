import { useEffect } from 'react'
import { useGitStore } from '../../store/git'
import { useWorkspaceStore } from '../../store/workspace'

function HistoryGraph(): React.JSX.Element {
  const root = useWorkspaceStore((s) => s.root)
  const changeTick = useWorkspaceStore((s) => s.changeTick)
  const { commits, status, refresh } = useGitStore()

  useEffect(() => {
    if (root) void refresh()
  }, [root, changeTick, refresh])

  if (!status?.isRepo) return <div className="panel-empty">No history.</div>

  return (
    <div className="history">
      {commits.map((c) => (
        <div key={c.hash} className="history-row">
          <div className="history-graph">
            <span className="history-dot" />
            {c.parents.length > 1 && <span className="history-merge" />}
          </div>
          <div className="history-meta">
            <div className="history-subject">
              {c.refs && <span className="history-ref">{c.refs}</span>}
              {c.subject}
            </div>
            <div className="history-sub">
              {c.hash.slice(0, 7)} · {c.author} · {c.date}
            </div>
          </div>
        </div>
      ))}
    </div>
  )
}

export default HistoryGraph
