import { create } from 'zustand'
import type { OpenTab } from '../types'

interface EditorState {
  tabs: OpenTab[]
  activePath: string | null
  openFile: (path: string, name: string) => Promise<void>
  setActive: (path: string) => void
  updateContent: (path: string, content: string) => void
  save: (path: string) => Promise<void>
  close: (path: string) => void
  /** called when an external change touches an open, non-dirty file */
  reloadIfOpen: (path: string) => Promise<void>
  closeActive: () => void
  cycleTab: (dir: 1 | -1) => void
  saveActive: () => Promise<void>
  saveAll: () => Promise<void>
}

export const useEditorStore = create<EditorState>((set, get) => ({
  tabs: [],
  activePath: null,
  openFile: async (path, name) => {
    const existing = get().tabs.find((t) => t.path === path)
    if (existing) {
      set({ activePath: path })
      return
    }
    const content = await window.api.fs.readFile(path)
    set((s) => ({
      tabs: [...s.tabs, { path, name, content, dirty: false }],
      activePath: path
    }))
  },
  setActive: (path) => set({ activePath: path }),
  updateContent: (path, content) =>
    set((s) => ({
      tabs: s.tabs.map((t) => (t.path === path ? { ...t, content, dirty: true } : t))
    })),
  save: async (path) => {
    const tab = get().tabs.find((t) => t.path === path)
    if (!tab) return
    await window.api.fs.writeFile(path, tab.content)
    set((s) => ({
      tabs: s.tabs.map((t) => (t.path === path ? { ...t, dirty: false } : t))
    }))
  },
  close: (path) =>
    set((s) => {
      const tabs = s.tabs.filter((t) => t.path !== path)
      const activePath =
        s.activePath === path ? (tabs.length ? tabs[tabs.length - 1].path : null) : s.activePath
      return { tabs, activePath }
    }),
  reloadIfOpen: async (path) => {
    const tab = get().tabs.find((t) => t.path === path)
    if (!tab || tab.dirty) return
    try {
      const content = await window.api.fs.readFile(path)
      set((s) => ({
        tabs: s.tabs.map((t) => (t.path === path ? { ...t, content } : t))
      }))
    } catch {
      // file may have been deleted; leave the tab as-is
    }
  },
  closeActive: () => {
    const { activePath, close } = get()
    if (activePath) close(activePath)
  },
  cycleTab: (dir) => {
    const { tabs, activePath } = get()
    if (!tabs.length) return
    const idx = tabs.findIndex((t) => t.path === activePath)
    const next = (idx + dir + tabs.length) % tabs.length
    set({ activePath: tabs[next].path })
  },
  saveActive: async () => {
    const { activePath, save } = get()
    if (activePath) await save(activePath)
  },
  saveAll: async () => {
    const { tabs } = get()
    for (const t of tabs.filter((t) => t.dirty)) {
      await get().save(t.path)
    }
  }
}))
