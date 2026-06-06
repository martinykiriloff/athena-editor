import { useEffect } from 'react'
import { Check, GitCommitVertical, Minus, Plus } from 'lucide-react'
import { useGitStore } from '../../store/git'
import { useWorkspaceStore } from '../../store/workspace'
import type { GitFile } from '../../types'

function statusLabel(f: GitFile): string {
  const code = (f.staged ? f.index : f.working) || '?'
  return code
}

function SourceControl(): React.JSX.Element {
  const root = useWorkspaceStore((s) => s.root)
  const changeTick = useWorkspaceStore((s) => s.changeTick)
  const {
    status,
    commitMessage,
    setCommitMessage,
    refresh,
    stage,
    unstage,
    stageAll,
    commit,
    openDiff
  } = useGitStore()

  useEffect(() => {
    if (root) void refresh()
  }, [root, changeTick, refresh])

  if (!root) return <div className="panel-empty">No folder open.</div>
  if (status && !status.isRepo) return <div className="panel-empty">Not a git repository.</div>

  const files = status?.files ?? []
  const staged = files.filter((f) => f.staged)
  const unstaged = files.filter((f) => !f.staged)
  const absPath = (rel: string): string => `${root}/${rel}`

  return (
    <div className="scm">
      <div className="scm-commit">
        <textarea
          placeholder="Commit message"
          value={commitMessage}
          onChange={(e) => setCommitMessage(e.target.value)}
        />
        <button className="scm-commit-btn" onClick={() => void commit()} disabled={!staged.length}>
          <GitCommitVertical size={14} /> Commit ({staged.length})
        </button>
      </div>

      <Section
        title="Staged Changes"
        files={staged}
        empty="Nothing staged"
        actionIcon={<Minus size={13} />}
        onAction={(p) => void unstage(p)}
        onOpen={(p) => openDiff(absPath(p))}
        statusLabel={statusLabel}
      />
      <div className="scm-section-head">
        <span>Changes</span>
        {unstaged.length > 0 && (
          <button className="scm-stage-all" onClick={() => void stageAll()} title="Stage all">
            <Check size={13} />
          </button>
        )}
      </div>
      <Section
        files={unstaged}
        empty="No changes"
        actionIcon={<Plus size={13} />}
        onAction={(p) => void stage(p)}
        onOpen={(p) => openDiff(absPath(p))}
        statusLabel={statusLabel}
      />
    </div>
  )
}

function Section({
  title,
  files,
  empty,
  actionIcon,
  onAction,
  onOpen,
  statusLabel
}: {
  title?: string
  files: GitFile[]
  empty: string
  actionIcon: React.ReactNode
  onAction: (path: string) => void
  onOpen: (path: string) => void
  statusLabel: (f: GitFile) => string
}): React.JSX.Element {
  return (
    <div className="scm-section">
      {title && <div className="scm-section-head">{title}</div>}
      {files.length === 0 ? (
        <div className="scm-empty">{empty}</div>
      ) : (
        files.map((f) => (
          <div key={f.path} className="scm-row">
            <span className="scm-file" onClick={() => onOpen(f.path)}>
              {f.path}
            </span>
            <span className="scm-status">{statusLabel(f)}</span>
            <button
              className="scm-action"
              onClick={(e) => {
                e.stopPropagation()
                onAction(f.path)
              }}
            >
              {actionIcon}
            </button>
          </div>
        ))
      )}
    </div>
  )
}

export default SourceControl
