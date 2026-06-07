import { create } from 'zustand'
import { lspClient } from '../components/editor/lspClient'

interface WorkspaceState {
  root: string | null
  changeTick: number
  lspRunning: boolean
  openFolder: () => Promise<void>
  ensureLsp: () => Promise<void>
  bumpChange: () => void
}

export const useWorkspaceStore = create<WorkspaceState>((set, get) => ({
  root: null,
  changeTick: 0,
  lspRunning: false,

  openFolder: async () => {
    const root = await window.api.workspace.open()
    if (root) {
      set({ root, lspRunning: false })
      lspClient.reset()
      // LSP starts lazily on first TS/JS file open (see lspProviders.ts).
    }
  },

  // Idempotent: safe to call on every TS/JS model creation.
  ensureLsp: async () => {
    const { root, lspRunning } = get()
    if (!root || lspRunning) return
    set({ lspRunning: true })
    try {
      await window.api.lsp.start(root)
      await lspClient.initialize(root)
    } catch (err) {
      console.error('[LSP] init error', err)
      set({ lspRunning: false })
    }
  },

  bumpChange: () => set((s) => ({ changeTick: s.changeTick + 1 }))
}))
