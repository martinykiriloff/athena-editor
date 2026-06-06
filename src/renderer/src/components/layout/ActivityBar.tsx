import { FlaskConical, Files, GitBranch, MessageSquare } from 'lucide-react'
import { useLayoutStore } from '../../store/layout'
import type { SidebarView } from '../../types'

const ITEMS: { view: SidebarView; icon: React.FC<{ size?: number }>; label: string }[] = [
  { view: 'explorer', icon: Files, label: 'Explorer' },
  { view: 'git', icon: GitBranch, label: 'Source Control' },
  { view: 'tests', icon: FlaskConical, label: 'Tests' }
]

function ActivityBar(): React.JSX.Element {
  const { sidebarView, setSidebarView, chatOpen, toggleChat } = useLayoutStore()
  return (
    <div className="activity-bar">
      {ITEMS.map(({ view, icon: Icon, label }) => (
        <button
          key={view}
          className={`activity-item${sidebarView === view ? ' active' : ''}`}
          title={label}
          onClick={() => setSidebarView(view)}
        >
          <Icon size={24} />
        </button>
      ))}
      <span className="activity-spacer" />
      <button
        className={`activity-item${chatOpen ? ' active' : ''}`}
        title="Claude (toggle right panel)"
        onClick={toggleChat}
      >
        <MessageSquare size={24} />
      </button>
    </div>
  )
}

export default ActivityBar
