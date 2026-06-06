import { useState, useEffect, useRef } from 'react'
import { useLayoutStore } from '../../store/layout'
import { useEditorStore } from '../../store/editor'
import { useWorkspaceStore } from '../../store/workspace'

function fuzzy(query: string, str: string): boolean {
  const q = query.toLowerCase()
  const s = str.toLowerCase()
  let qi = 0
  for (let i = 0; i < s.length && qi < q.length; i++) {
    if (s[i] === q[qi]) qi++
  }
  return qi === q.length
}

function basename(p: string): string {
  return p.split(/[/\\]/).pop() ?? p
}

function relPath(root: string, abs: string): string {
  return abs.startsWith(root) ? abs.slice(root.length).replace(/^\//, '') : abs
}

export default function QuickOpen(): React.JSX.Element {
  const closePalette = useLayoutStore((s) => s.closePalette)
  const root = useWorkspaceStore((s) => s.root)
  const [query, setQuery] = useState('')
  const [files, setFiles] = useState<string[]>([])
  const [active, setActive] = useState(0)
  const inputRef = useRef<HTMLInputElement>(null)
  const listRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    inputRef.current?.focus()
    if (!root) return
    void window.api.fs.listFiles().then(setFiles)
  }, [root])

  const shown = (
    query ? files.filter((f) => fuzzy(query, basename(f)) || fuzzy(query, f)) : files
  ).slice(0, 50)

  const pick = (path: string): void => {
    void useEditorStore.getState().openFile(path, basename(path))
    closePalette()
  }

  const onKey = (e: React.KeyboardEvent): void => {
    if (e.key === 'Escape') {
      closePalette()
      return
    }
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setActive((a) => Math.min(a + 1, shown.length - 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActive((a) => Math.max(a - 1, 0))
    } else if (e.key === 'Enter' && shown[active]) pick(shown[active])
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
          placeholder="Go to file…"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value)
            setActive(0)
          }}
          onKeyDown={onKey}
        />
        <div ref={listRef} className="palette-list">
          {!root && <div className="palette-empty">No folder open</div>}
          {root && shown.length === 0 && <div className="palette-empty">No matches</div>}
          {shown.map((f, i) => (
            <div
              key={f}
              className={`palette-item${i === active ? ' active' : ''}`}
              onMouseEnter={() => setActive(i)}
              onMouseDown={() => pick(f)}
            >
              <span className="palette-item-name">{basename(f)}</span>
              {root && <span className="palette-item-path">{relPath(root, f)}</span>}
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
