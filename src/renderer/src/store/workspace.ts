import { create } from 'zustand'
import { lspClient } from '../components/editor/lspClient'

interface WorkspaceState {
  root: string | null
  /** bumped on any fs change to let the tree know to refresh */
  changeTick: number
  openFolder: () => Promise<void>
  bumpChange: () => void
}

export const useWorkspaceStore = create<WorkspaceState>((set) => ({
  root: null,
  changeTick: 0,
  openFolder: async () => {
    const root = await window.api.workspace.open()
    if (root) {
      set({ root })
      lspClient.reset()
      await window.api.lsp.start(root)
      lspClient.initialize(root).catch((err) => console.error('[LSP] init error', err))
    }
  },
  bumpChange: () => set((s) => ({ changeTick: s.changeTick + 1 }))
}))
