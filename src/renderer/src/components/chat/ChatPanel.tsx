import { useEffect, useMemo, useRef, useState } from 'react'
import { Send, SlashSquare, Square, Wrench } from 'lucide-react'
import { useChatStore } from '../../store/chat'
import type { SlashCmd } from '../../types'

function ChatPanel(): React.JSX.Element {
  const { messages, running, pending, commands, send, abort, respond } = useChatStore()
  const [input, setInput] = useState('')
  const [browseOpen, setBrowseOpen] = useState(false)
  const [highlight, setHighlight] = useState(0)
  const scrollRef = useRef<HTMLDivElement>(null)
  const textareaRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight })
  }, [messages, pending])

  // Slash typeahead: active while the input is "/partial" with no space yet.
  const slashMode = input.startsWith('/') && !input.includes(' ')
  const term = slashMode ? input.slice(1).toLowerCase() : ''
  const showMenu = (slashMode || browseOpen) && commands.length > 0

  const list = useMemo<SlashCmd[]>(() => {
    if (!showMenu) return []
    const filtered = commands.filter(
      (c) =>
        !term ||
        c.name.toLowerCase().includes(term) ||
        c.aliases?.some((a) => a.toLowerCase().includes(term))
    )
    return filtered.slice(0, 100)
  }, [commands, term, showMenu])

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setHighlight(0)
  }, [term, browseOpen])

  const submit = (): void => {
    const text = input
    setInput('')
    setBrowseOpen(false)
    void send(text)
  }

  const pickCommand = (c: SlashCmd): void => {
    setInput(`/${c.name} `)
    setBrowseOpen(false)
    textareaRef.current?.focus()
  }

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>): void => {
    if (showMenu && list.length) {
      if (e.key === 'ArrowDown') {
        e.preventDefault()
        setHighlight((h) => (h + 1) % list.length)
        return
      }
      if (e.key === 'ArrowUp') {
        e.preventDefault()
        setHighlight((h) => (h - 1 + list.length) % list.length)
        return
      }
      if (e.key === 'Tab' || (e.key === 'Enter' && slashMode)) {
        e.preventDefault()
        pickCommand(list[highlight])
        return
      }
      if (e.key === 'Escape') {
        e.preventDefault()
        setBrowseOpen(false)
        if (slashMode) setInput('')
        return
      }
    }
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      submit()
    }
  }

  return (
    <div className="chat-panel">
      <div className="chat-messages" ref={scrollRef}>
        {messages.length === 0 && (
          <div className="chat-hint">
            Ask Claude to read, explain, or edit files — or type <code>/</code> for commands.
          </div>
        )}
        {messages.map((m) => (
          <div key={m.id} className={`chat-msg ${m.role}`}>
            {m.role === 'tool' ? (
              <span className="tool-line">
                <Wrench size={12} /> {m.text}
              </span>
            ) : (
              <pre className="msg-text">{m.text}</pre>
            )}
          </div>
        ))}
        {running && !pending && <div className="chat-msg assistant thinking">…</div>}
      </div>

      {pending && (
        <div className="permission-box">
          <div className="permission-title">
            {pending.title ?? `Claude wants to use ${pending.toolName}`}
          </div>
          <pre className="permission-input">{JSON.stringify(pending.input, null, 2)}</pre>
          <div className="permission-actions">
            <button className="allow" onClick={() => respond(true)}>
              Allow
            </button>
            <button className="deny" onClick={() => respond(false)}>
              Deny
            </button>
          </div>
        </div>
      )}

      {showMenu && (
        <div className="cmd-menu">
          <div className="cmd-menu-head">
            Commands {term && `· /${term}`} ({list.length})
          </div>
          <div className="cmd-menu-list">
            {list.map((c, i) => (
              <div
                key={c.name}
                className={`cmd-item${i === highlight ? ' active' : ''}`}
                onMouseEnter={() => setHighlight(i)}
                onClick={() => pickCommand(c)}
              >
                <span className="cmd-name">/{c.name}</span>
                {c.argumentHint && <span className="cmd-arg">{c.argumentHint}</span>}
                <span className="cmd-desc">{c.description}</span>
              </div>
            ))}
            {list.length === 0 && <div className="cmd-empty">No matching command</div>}
          </div>
        </div>
      )}

      <div className="chat-input">
        <button
          className="chat-cmd-btn"
          title="Browse commands"
          onClick={() => {
            setBrowseOpen((v) => !v)
            textareaRef.current?.focus()
          }}
        >
          <SlashSquare size={16} />
        </button>
        <textarea
          ref={textareaRef}
          value={input}
          placeholder="Ask Claude…  (/ for commands)"
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={onKeyDown}
        />
        {running ? (
          <button className="chat-stop" onClick={abort} title="Stop">
            <Square size={16} />
          </button>
        ) : (
          <button className="chat-send" onClick={submit} disabled={!input.trim()} title="Send">
            <Send size={16} />
          </button>
        )}
      </div>
    </div>
  )
}

export default ChatPanel
