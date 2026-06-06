import { useEffect, useState } from 'react'
import { DiffEditor } from '@monaco-editor/react'
import { X } from 'lucide-react'
import { useGitStore } from '../../store/git'
import { languageForPath } from '../editor/language'
import { DARCULA, baseEditorOptions } from '../editor/theme'

interface DiffData {
  path: string
  original: string
  modified: string
}

function DiffViewer(): React.JSX.Element | null {
  const diffPath = useGitStore((s) => s.diffPath)
  const openDiff = useGitStore((s) => s.openDiff)
  const [data, setData] = useState<DiffData | null>(null)

  useEffect(() => {
    if (!diffPath) return
    let cancelled = false
    void (window.api.git.diff(diffPath) as Promise<{ original: string; modified: string }>).then(
      (d) => {
        if (!cancelled) setData({ path: diffPath, ...d })
      }
    )
    return () => {
      cancelled = true
    }
  }, [diffPath])

  if (!diffPath) return null

  const name = diffPath.split(/[/\\]/).pop() ?? diffPath
  const ready = data && data.path === diffPath

  return (
    <div className="diff-overlay">
      <div className="diff-header">
        <span>{name} (working tree ↔ HEAD)</span>
        <button className="diff-close" onClick={() => openDiff(null)}>
          <X size={14} />
        </button>
      </div>
      <div className="diff-body">
        {ready && (
          <DiffEditor
            theme={DARCULA}
            original={data.original}
            modified={data.modified}
            language={languageForPath(diffPath)}
            options={{ ...baseEditorOptions, readOnly: true, renderSideBySide: true }}
          />
        )}
      </div>
    </div>
  )
}

export default DiffViewer
