import { create } from 'zustand'
import type { ChatMessage, ClaudeEvent, PendingPermission, SlashCmd } from '../types'

let idCounter = 0
const nextId = (): string => `m${++idCounter}`

interface ChatState {
  messages: ChatMessage[]
  running: boolean
  pending: PendingPermission | null
  currentAssistantId: string | null
  subscribed: boolean
  authSource: string | null
  model: string | null
  authError: boolean
  commands: SlashCmd[]
  subscribe: () => void
  loadCommands: () => Promise<void>
  send: (prompt: string) => Promise<void>
  abort: () => void
  respond: (allow: boolean) => void
  handleEvent: (ev: ClaudeEvent) => void
}

export const useChatStore = create<ChatState>((set, get) => ({
  messages: [],
  running: false,
  pending: null,
  currentAssistantId: null,
  subscribed: false,
  authSource: null,
  model: null,
  authError: false,
  commands: [],

  subscribe: () => {
    if (get().subscribed) return
    window.api.claude.onEvent((ev) => get().handleEvent(ev as ClaudeEvent))
    set({ subscribed: true })
    void get().loadCommands()
  },

  loadCommands: async () => {
    if (get().commands.length) return
    try {
      const commands = (await window.api.claude.listCommands()) as SlashCmd[]
      set({ commands })
    } catch {
      // ignore — commands stay empty
    }
  },

  send: async (prompt) => {
    if (get().running || !prompt.trim()) return
    set((s) => ({
      messages: [...s.messages, { id: nextId(), role: 'user', text: prompt }],
      running: true,
      currentAssistantId: null
    }))
    await window.api.claude.send(prompt)
  },

  abort: () => {
    void window.api.claude.abort()
    set({ running: false, pending: null, currentAssistantId: null })
  },

  respond: (allow) => {
    const pending = get().pending
    if (!pending) return
    void window.api.claude.respondPermission(pending.id, allow)
    set({ pending: null })
  },

  handleEvent: (ev) => {
    switch (ev.kind) {
      case 'assistant': {
        const curId = get().currentAssistantId
        if (curId) {
          set((s) => ({
            messages: s.messages.map((m) => (m.id === curId ? { ...m, text: m.text + ev.text } : m))
          }))
        } else {
          const id = nextId()
          set((s) => ({
            messages: [...s.messages, { id, role: 'assistant', text: ev.text }],
            currentAssistantId: id
          }))
        }
        break
      }
      case 'tool_use': {
        set((s) => ({
          messages: [
            ...s.messages,
            { id: nextId(), role: 'tool', text: `${ev.name} ${summarize(ev.input)}` }
          ],
          currentAssistantId: null
        }))
        break
      }
      case 'permission': {
        set({ pending: { id: ev.id, toolName: ev.toolName, input: ev.input, title: ev.title } })
        break
      }
      case 'error': {
        const isAuth = /login|authenticat|sign[- ]?in|credential|api key|unauthor|expired/i.test(
          ev.message
        )
        set((s) => ({
          messages: [...s.messages, { id: nextId(), role: 'error', text: ev.message }],
          running: false,
          authError: isAuth ? true : s.authError
        }))
        break
      }
      case 'auth': {
        set({ authSource: ev.source, model: ev.model, authError: false })
        break
      }
      case 'result': {
        set({ currentAssistantId: null })
        break
      }
      case 'done': {
        set({ running: false, currentAssistantId: null })
        break
      }
    }
  }
}))

function summarize(input: unknown): string {
  if (input && typeof input === 'object') {
    const obj = input as Record<string, unknown>
    const key = obj.file_path ?? obj.path ?? obj.command ?? obj.pattern
    if (key) return `→ ${String(key)}`
  }
  return ''
}
