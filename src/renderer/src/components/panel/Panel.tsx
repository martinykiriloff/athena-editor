import { X } from 'lucide-react'
import { useLayoutStore } from '../../store/layout'
import { useProblemsStore } from '../../store/problems'
import type { PanelTab } from '../../types'
import Terminal from './Terminal'
import ProblemsPanel from './ProblemsPanel'
import TestResultsPanel from './TestResultsPanel'

const TABS: { id: PanelTab; label: string }[] = [
  { id: 'terminal', label: 'Terminal' },
  { id: 'problems', label: 'Problems' },
  { id: 'tests', label: 'Test Results' }
]

function Panel(): React.JSX.Element {
  const { panelTab, setPanelTab, togglePanel } = useLayoutStore()
  const problemCount = useProblemsStore((s) =>
    Object.values(s.byFile).reduce((n, m) => n + m.length, 0)
  )

  return (
    <div className="panel">
      <div className="panel-tabs">
        {TABS.map((t) => (
          <button
            key={t.id}
            className={`panel-tab${panelTab === t.id ? ' active' : ''}`}
            onClick={() => setPanelTab(t.id)}
          >
            {t.label}
            {t.id === 'problems' && problemCount > 0 && (
              <span className="panel-badge">{problemCount}</span>
            )}
          </button>
        ))}
        <span className="panel-spacer" />
        <button className="panel-close" onClick={togglePanel} title="Close panel">
          <X size={14} />
        </button>
      </div>
      <div className="panel-body">
        {/* Terminal stays mounted so its pty session survives tab switches. */}
        <div className="panel-view" style={{ display: panelTab === 'terminal' ? 'block' : 'none' }}>
          <Terminal />
        </div>
        {panelTab === 'problems' && (
          <div className="panel-view">
            <ProblemsPanel />
          </div>
        )}
        {panelTab === 'tests' && (
          <div className="panel-view">
            <TestResultsPanel />
          </div>
        )}
      </div>
    </div>
  )
}

export default Panel
