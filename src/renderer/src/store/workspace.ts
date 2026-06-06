import { create } from 'zustand'

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
    if (root) set({ root })
  },
  bumpChange: () => set((s) => ({ changeTick: s.changeTick + 1 }))
}))
