import { useEffect } from 'react'
import { Allotment } from 'allotment'
import ActivityBar from './components/layout/ActivityBar'
import SideBar from './components/layout/SideBar'
import EditorArea from './components/layout/EditorArea'
import StatusBar from './components/layout/StatusBar'
import Panel from './components/panel/Panel'
import ChatDock from './components/chat/ChatDock'
import QuickOpen from './components/palette/QuickOpen'
import CommandPalette from './components/palette/CommandPalette'
import { useChatStore } from './store/chat'
import { useJestStore } from './store/jest'
import { useEditorStore } from './store/editor'
import { useWorkspaceStore } from './store/workspace'
import { useLayoutStore } from './store/layout'
import { useKeymap } from './hooks/useKeymap'

function App(): React.JSX.Element {
  const subscribeChat = useChatStore((s) => s.subscribe)
  const subscribeJest = useJestStore((s) => s.subscribe)
  const bumpChange = useWorkspaceStore((s) => s.bumpChange)
  const panelOpen = useLayoutStore((s) => s.panelOpen)
  const chatOpen = useLayoutStore((s) => s.chatOpen)
  const sidebarOpen = useLayoutStore((s) => s.sidebarOpen)
  const paletteOpen = useLayoutStore((s) => s.paletteOpen)
  const paletteMode = useLayoutStore((s) => s.paletteMode)

  useKeymap()

  useEffect(() => {
    subscribeChat()
    subscribeJest()
    const off = window.api.onFsChanged((payload) => {
      bumpChange()
      if (payload.type === 'change') {
        void useEditorStore.getState().reloadIfOpen(payload.path)
      }
    })
    return () => {
      off()
    }
  }, [subscribeChat, subscribeJest, bumpChange])

  return (
    <div className="app">
      <div className="app-main">
        <ActivityBar />
        <Allotment proportionalLayout={false}>
          {sidebarOpen && (
            <Allotment.Pane preferredSize={300} minSize={180} snap>
              <SideBar />
            </Allotment.Pane>
          )}
          <Allotment.Pane>
            <Allotment vertical proportionalLayout={false}>
              <Allotment.Pane>
                <EditorArea />
              </Allotment.Pane>
              {panelOpen && (
                <Allotment.Pane preferredSize={260} minSize={100}>
                  <Panel />
                </Allotment.Pane>
              )}
            </Allotment>
          </Allotment.Pane>
          {chatOpen && (
            <Allotment.Pane preferredSize={380} minSize={260} snap>
              <ChatDock />
            </Allotment.Pane>
          )}
        </Allotment>
      </div>
      <StatusBar />
      {paletteOpen && paletteMode === 'files' && <QuickOpen />}
      {paletteOpen && paletteMode === 'commands' && <CommandPalette />}
    </div>
  )
}

export default App
