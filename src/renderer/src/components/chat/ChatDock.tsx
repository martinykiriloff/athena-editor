import { LogIn, X } from 'lucide-react'
import { useLayoutStore } from '../../store/layout'
import { useChatStore } from '../../store/chat'
import ChatPanel from './ChatPanel'

function authLabel(source: string | null): { text: string; ok: boolean } {
  switch (source) {
    case 'oauth':
    case 'none': // subscription/account session — no API key in use
      return { text: 'Claude account', ok: true }
    case 'user':
    case 'project':
    case 'org':
      return { text: 'API key', ok: true }
    case 'temporary':
      return { text: 'temporary token', ok: true }
    case null:
      return { text: '', ok: true }
    default:
      return { text: source, ok: true }
  }
}

function ChatDock(): React.JSX.Element {
  const toggleChat = useLayoutStore((s) => s.toggleChat)
  const openPanel = useLayoutStore((s) => s.openPanel)
  const authSource = useChatStore((s) => s.authSource)
  const model = useChatStore((s) => s.model)
  const authError = useChatStore((s) => s.authError)
  const auth = authLabel(authSource)

  return (
    <div className="chat-dock">
      <div className="chat-dock-header">
        <span>Claude</span>
        <span className={`chat-auth${authError ? '' : ' ok'}`} title={model ?? ''}>
          {authError ? 'not signed in' : auth.text}
        </span>
        <button className="chat-dock-close" onClick={toggleChat} title="Close Claude">
          <X size={14} />
        </button>
      </div>
      {authError && (
        <div className="chat-signin">
          <span>Sign in with your Claude account to use the assistant.</span>
          <button onClick={() => openPanel('terminal')}>
            <LogIn size={13} /> Open terminal — run <code>claude</code> then <code>/login</code>
          </button>
        </div>
      )}
      <div className="chat-dock-body">
        <ChatPanel />
      </div>
    </div>
  )
}

export default ChatDock
