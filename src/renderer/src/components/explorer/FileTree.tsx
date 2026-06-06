import { useEffect, useState } from 'react'
import { ChevronDown, ChevronRight, File, Folder, FolderOpen } from 'lucide-react'
import { useEditorStore } from '../../store/editor'
import { useWorkspaceStore } from '../../store/workspace'
import type { DirEntry } from '../../types'

function TreeNode({ entry, depth }: { entry: DirEntry; depth: number }): React.JSX.Element {
  const [open, setOpen] = useState(false)
  const [children, setChildren] = useState<DirEntry[] | null>(null)
  const changeTick = useWorkspaceStore((s) => s.changeTick)
  const openFile = useEditorStore((s) => s.openFile)
  const activePath = useEditorStore((s) => s.activePath)

  const loadChildren = async (): Promise<void> => {
    const items = await window.api.fs.readDir(entry.path)
    setChildren(items)
  }

  // refresh an expanded folder when the workspace changes (external fs is the source of truth)
  useEffect(() => {
    if (!open || entry.type !== 'dir') return
    // eslint-disable-next-line react-hooks/set-state-in-effect
    void loadChildren()
  }, [changeTick]) // eslint-disable-line react-hooks/exhaustive-deps

  const onClick = async (): Promise<void> => {
    if (entry.type === 'dir') {
      const next = !open
      setOpen(next)
      if (next && !children) await loadChildren()
    } else {
      await openFile(entry.path, entry.name)
    }
  }

  const isActive = entry.type === 'file' && activePath === entry.path

  return (
    <>
      <div
        className={`tree-node${isActive ? ' active' : ''}`}
        style={{ paddingLeft: depth * 12 + 6 }}
        onClick={onClick}
      >
        {entry.type === 'dir' ? (
          <>
            {open ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
            {open ? <FolderOpen size={14} /> : <Folder size={14} />}
          </>
        ) : (
          <>
            <span style={{ width: 14, display: 'inline-block' }} />
            <File size={14} />
          </>
        )}
        <span className="tree-label">{entry.name}</span>
      </div>
      {open &&
        children?.map((child) => <TreeNode key={child.path} entry={child} depth={depth + 1} />)}
    </>
  )
}

function FileTree(): React.JSX.Element {
  const root = useWorkspaceStore((s) => s.root)
  const openFolder = useWorkspaceStore((s) => s.openFolder)
  const changeTick = useWorkspaceStore((s) => s.changeTick)
  const [entries, setEntries] = useState<DirEntry[]>([])

  useEffect(() => {
    if (root) void window.api.fs.readDir(root).then(setEntries)
  }, [root, changeTick])

  if (!root) {
    return (
      <div className="explorer-empty">
        <p>No folder open</p>
        <button onClick={() => void openFolder()}>Open Folder</button>
      </div>
    )
  }

  return (
    <div className="file-tree">
      {entries.map((e) => (
        <TreeNode key={e.path} entry={e} depth={0} />
      ))}
    </div>
  )
}

export default FileTree
