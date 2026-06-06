import { create } from 'zustand'
import type { JestEvent, JestReport } from '../types'

interface JestState {
  report: JestReport | null
  running: boolean
  error: string | null
  subscribed: boolean
  subscribe: () => void
  run: (file?: string) => Promise<void>
  stop: () => void
  handleEvent: (ev: JestEvent) => void
}

export const useJestStore = create<JestState>((set, get) => ({
  report: null,
  running: false,
  error: null,
  subscribed: false,

  subscribe: () => {
    if (get().subscribed) return
    window.api.jest.onEvent((ev) => get().handleEvent(ev as JestEvent))
    set({ subscribed: true })
  },

  run: async (file) => {
    if (get().running) return
    set({ running: true, error: null })
    await window.api.jest.run(file)
  },

  stop: () => {
    void window.api.jest.stop()
    set({ running: false })
  },

  handleEvent: (ev) => {
    switch (ev.kind) {
      case 'start':
        set({ running: true, error: null })
        break
      case 'result':
        set({ report: ev.report })
        break
      case 'error':
        set({ error: ev.message })
        break
      case 'done':
        set({ running: false })
        break
    }
  }
}))
