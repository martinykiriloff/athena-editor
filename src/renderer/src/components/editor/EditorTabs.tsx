import { X } from 'lucide-react'
import { useEditorStore } from '../../store/editor'

function EditorTabs(): React.JSX.Element {
  const { tabs, activePath, setActive, close } = useEditorStore()
  return (
    <div className="editor-tabs">
      {tabs.map((t) => (
        <div
          key={t.path}
          className={`editor-tab${activePath === t.path ? ' active' : ''}`}
          onClick={() => setActive(t.path)}
        >
          <span className="tab-name">
            {t.dirty ? '● ' : ''}
            {t.name}
          </span>
          <span
            className="tab-close"
            onClick={(e) => {
              e.stopPropagation()
              close(t.path)
            }}
          >
            <X size={12} />
          </span>
        </div>
      ))}
    </div>
  )
}

export default EditorTabs
