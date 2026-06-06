import { create } from 'zustand'
import type { PanelTab, SidebarView } from '../types'

export type PaletteMode = 'files' | 'commands'

interface LayoutState {
  sidebarView: SidebarView
  sidebarOpen: boolean
  panelOpen: boolean
  panelTab: PanelTab
  chatOpen: boolean
  paletteOpen: boolean
  paletteMode: PaletteMode
  setSidebarView: (v: SidebarView) => void
  showView: (v: SidebarView) => void
  toggleSidebar: () => void
  togglePanel: () => void
  setPanelTab: (t: PanelTab) => void
  openPanel: (t: PanelTab) => void
  toggleChat: () => void
  openPalette: (mode: PaletteMode) => void
  closePalette: () => void
}

export const useLayoutStore = create<LayoutState>((set) => ({
  sidebarView: 'explorer',
  sidebarOpen: true,
  panelOpen: false,
  panelTab: 'terminal',
  chatOpen: true,
  paletteOpen: false,
  paletteMode: 'files',
  setSidebarView: (sidebarView) => set({ sidebarView }),
  // switch to a view and make sure the sidebar is visible
  showView: (sidebarView) => set({ sidebarView, sidebarOpen: true }),
  toggleSidebar: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
  togglePanel: () => set((s) => ({ panelOpen: !s.panelOpen })),
  setPanelTab: (panelTab) => set({ panelTab }),
  openPanel: (panelTab) => set({ panelTab, panelOpen: true }),
  toggleChat: () => set((s) => ({ chatOpen: !s.chatOpen })),
  openPalette: (paletteMode) => set({ paletteOpen: true, paletteMode }),
  closePalette: () => set({ paletteOpen: false })
}))
