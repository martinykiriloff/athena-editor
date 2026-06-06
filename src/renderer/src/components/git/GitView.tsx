import SourceControl from './SourceControl'
import HistoryGraph from './HistoryGraph'

function GitView(): React.JSX.Element {
  return (
    <div className="git-view">
      <div className="git-section">
        <SourceControl />
      </div>
      <div className="git-divider">History</div>
      <div className="git-section git-history-section">
        <HistoryGraph />
      </div>
    </div>
  )
}

export default GitView
