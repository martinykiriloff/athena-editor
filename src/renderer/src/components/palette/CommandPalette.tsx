import { useState, useEffect, useRef } from 'react'
import { useLayoutStore } from '../../store/layout'
import { useEditorStore } from '../../store/editor'
import { useWorkspaceStore } from '../../store/workspace'

interface Command {
  id: string
  label: string
  keybinding?: string
  run: () => void
}

function buildCommands(close: () => void): Command[] {
  const wrap = (fn: () => void) => () => {
    fn()
    close()
  }
  return [
    {
      id: 'open-folder',
      label: 'File: Open Folder',
      run: wrap(() => void useWorkspaceStore.getState().openFolder())
    },
    {
      id: 'save',
      label: 'File: Save',
      keybinding: '⌘S',
      run: wrap(() => void useEditorStore.getState().saveActive())
    },
    {
      id: 'save-all',
      label: 'File: Save All',
      keybinding: '⌘⇧S',
      run: wrap(() => void useEditorStore.getState().saveAll())
    },
    {
      id: 'close-editor',
      label: 'View: Close Editor',
      keybinding: '⌘W',
      run: wrap(() => useEditorStore.getState().closeActive())
    },
    {
      id: 'next-editor',
      label: 'View: Next Editor',
      keybinding: '⌃Tab',
      run: wrap(() => useEditorStore.getState().cycleTab(1))
    },
    {
      id: 'prev-editor',
      label: 'View: Previous Editor',
      keybinding: '⌃⇧Tab',
      run: wrap(() => useEditorStore.getState().cycleTab(-1))
    },
    {
      id: 'toggle-sidebar',
      label: 'View: Toggle Side Bar',
      keybinding: '⌘B',
      run: wrap(() => useLayoutStore.getState().toggleSidebar())
    },
    {
      id: 'toggle-panel',
      label: 'View: Toggle Panel',
      keybinding: '⌘J',
      run: wrap(() => useLayoutStore.getState().togglePanel())
    },
    {
      id: 'show-explorer',
      label: 'View: Show Explorer',
      keybinding: '⌘⇧E',
      run: wrap(() => useLayoutStore.getState().showView('explorer'))
    },
    {
      id: 'show-git',
      label: 'View: Show Source Control',
      keybinding: '⌘⇧G',
      run: wrap(() => useLayoutStore.getState().showView('git'))
    },
    {
      id: 'show-tests',
      label: 'View: Show Tests',
      keybinding: '⌘⇧T',
      run: wrap(() => useLayoutStore.getState().showView('tests'))
    },
    {
      id: 'quick-open',
      label: 'Go to File…',
      keybinding: '⌘P',
      run: wrap(() => useLayoutStore.getState().openPalette('files'))
    }
  ]
}

export default function CommandPalette(): React.JSX.Element {
  const closePalette = useLayoutStore((s) => s.closePalette)
  const [query, setQuery] = useState('')
  const [active, setActive] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  const commands = buildCommands(closePalette)
  const filtered = query
    ? commands.filter((c) => c.label.toLowerCase().includes(query.toLowerCase()))
    : commands

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  const onKey = (e: React.KeyboardEvent): void => {
    if (e.key === 'Escape') {
      closePalette()
      return
    }
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setActive((a) => Math.min(a + 1, filtered.length - 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActive((a) => Math.max(a - 1, 0))
    } else if (e.key === 'Enter' && filtered[active]) filtered[active].run()
  }

  useEffect(() => {
    listRef.current?.querySelector('.palette-item.active')?.scrollIntoView({ block: 'nearest' })
  }, [active])

  return (
    <div className="palette-overlay" onMouseDown={closePalette}>
      <div className="palette" onMouseDown={(e) => e.stopPropagation()}>
        <input
          ref={inputRef}
          className="palette-input"
          placeholder="Type a command…"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value)
            setActive(0)
          }}
          onKeyDown={onKey}
        />
        <div ref={listRef} className="palette-list">
          {filtered.length === 0 && <div className="palette-empty">No commands found</div>}
          {filtered.map((cmd, i) => (
            <div
              key={cmd.id}
              className={`palette-item${i === active ? ' active' : ''}`}
              onMouseEnter={() => setActive(i)}
              onMouseDown={() => cmd.run()}
            >
              <span className="palette-item-name">{cmd.label}</span>
              {cmd.keybinding && <span className="palette-item-kb">{cmd.keybinding}</span>}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
