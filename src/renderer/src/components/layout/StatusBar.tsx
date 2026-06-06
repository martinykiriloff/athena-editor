import { useEffect } from 'react'
import { AlertCircle, AlertTriangle, GitBranch, TerminalSquare } from 'lucide-react'
import { useEditorStore } from '../../store/editor'
import { useWorkspaceStore } from '../../store/workspace'
import { useGitStore } from '../../store/git'
import { useProblemsStore } from '../../store/problems'
import { useLayoutStore } from '../../store/layout'

function StatusBar(): React.JSX.Element {
  const root = useWorkspaceStore((s) => s.root)
  const changeTick = useWorkspaceStore((s) => s.changeTick)
  const tabs = useEditorStore((s) => s.tabs)
  const activePath = useEditorStore((s) => s.activePath)
  const status = useGitStore((s) => s.status)
  const refresh = useGitStore((s) => s.refresh)
  const byFile = useProblemsStore((s) => s.byFile)
  const openPanel = useLayoutStore((s) => s.openPanel)
  const togglePanel = useLayoutStore((s) => s.togglePanel)

  const active = tabs.find((t) => t.path === activePath)

  useEffect(() => {
    if (root) void refresh()
  }, [root, changeTick, refresh])

  const all = Object.values(byFile).flat()
  const errors = all.filter((m) => m.severity === 2).length
  const warnings = all.filter((m) => m.severity === 1).length

  return (
    <div className="status-bar">
      {status?.isRepo && (
        <span
          className="status-item"
          onClick={() => useLayoutStore.getState().setSidebarView('git')}
        >
          <GitBranch size={12} /> {status.branch}
          {status.ahead > 0 ? ` ↑${status.ahead}` : ''}
          {status.behind > 0 ? ` ↓${status.behind}` : ''}
        </span>
      )}
      <span className="status-item" onClick={() => openPanel('problems')}>
        <AlertCircle size={12} /> {errors} <AlertTriangle size={12} /> {warnings}
      </span>
      <span className="spacer" />
      {active && <span>{active.dirty ? '● unsaved' : 'saved'}</span>}
      <span className="status-item" onClick={togglePanel} title="Toggle panel (Ctrl+`)">
        <TerminalSquare size={12} />
      </span>
      <span>{root ? folderName(root) : 'No folder'}</span>
    </div>
  )
}

function folderName(p: string): string {
  const parts = p.split(/[/\\]/).filter(Boolean)
  return parts[parts.length - 1] ?? p
}

export default StatusBar
