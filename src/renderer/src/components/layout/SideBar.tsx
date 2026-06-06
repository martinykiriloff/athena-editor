import { useWorkspaceStore } from '../../store/workspace'
import { useLayoutStore } from '../../store/layout'
import FileTree from '../explorer/FileTree'
import GitView from '../git/GitView'
import TestExplorer from '../tests/TestExplorer'

const TITLES: Record<string, string> = {
  explorer: 'Explorer',
  git: 'Source Control',
  tests: 'Tests'
}

function SideBar(): React.JSX.Element {
  const view = useLayoutStore((s) => s.sidebarView)
  const openFolder = useWorkspaceStore((s) => s.openFolder)

  return (
    <div className="sidebar">
      <div className="sidebar-header">
        <span>{TITLES[view]}</span>
        {view === 'explorer' && (
          <button className="sidebar-action" onClick={() => void openFolder()}>
            Open
          </button>
        )}
      </div>
      <div className="sidebar-body">
        {view === 'explorer' && <FileTree />}
        {view === 'git' && <GitView />}
        {view === 'tests' && <TestExplorer />}
      </div>
    </div>
  )
}

export default SideBar
