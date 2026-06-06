import EditorTabs from '../editor/EditorTabs'
import MonacoEditor from '../editor/MonacoEditor'
import DiffViewer from '../git/DiffViewer'

function EditorArea(): React.JSX.Element {
  return (
    <div className="editor-area">
      <EditorTabs />
      <div className="editor-host">
        <MonacoEditor />
        <DiffViewer />
      </div>
    </div>
  )
}

export default EditorArea
