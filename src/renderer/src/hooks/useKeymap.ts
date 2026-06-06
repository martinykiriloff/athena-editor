import { useEffect } from 'react'
import { useLayoutStore } from '../store/layout'
import { useEditorStore } from '../store/editor'

export function useKeymap(): void {
  useEffect(() => {
    const handler = (e: KeyboardEvent): void => {
      const mod = e.metaKey || e.ctrlKey
      const key = e.key.toLowerCase()

      // --- Palette ---
      if (mod && !e.shiftKey && !e.altKey && key === 'p') {
        e.preventDefault()
        e.stopPropagation()
        useLayoutStore.getState().openPalette('files')
        return
      }
      if (mod && e.shiftKey && key === 'p') {
        e.preventDefault()
        e.stopPropagation()
        useLayoutStore.getState().openPalette('commands')
        return
      }

      // --- Sidebar / Panel ---
      if (mod && !e.shiftKey && !e.altKey && key === 'b') {
        e.preventDefault()
        e.stopPropagation()
        useLayoutStore.getState().toggleSidebar()
        return
      }
      if (mod && !e.shiftKey && !e.altKey && (key === 'j' || key === '`')) {
        e.preventDefault()
        e.stopPropagation()
        useLayoutStore.getState().togglePanel()
        return
      }

      // --- Save ---
      if (mod && !e.shiftKey && !e.altKey && key === 's') {
        e.preventDefault()
        e.stopPropagation()
        void useEditorStore.getState().saveActive()
        return
      }
      if (mod && e.shiftKey && key === 's') {
        e.preventDefault()
        e.stopPropagation()
        void useEditorStore.getState().saveAll()
        return
      }

      // --- Close tab ---
      if (mod && !e.shiftKey && !e.altKey && key === 'w') {
        e.preventDefault()
        e.stopPropagation()
        useEditorStore.getState().closeActive()
        return
      }

      // --- Tab cycling: Ctrl+Tab / Ctrl+Shift+Tab ---
      if (e.ctrlKey && e.key === 'Tab') {
        e.preventDefault()
        e.stopPropagation()
        useEditorStore.getState().cycleTab(e.shiftKey ? -1 : 1)
        return
      }
      // Cmd+Shift+] / Cmd+Shift+[ (VS Code Mac style)
      if (mod && e.shiftKey && (e.key === ']' || e.key === '}')) {
        e.preventDefault()
        e.stopPropagation()
        useEditorStore.getState().cycleTab(1)
        return
      }
      if (mod && e.shiftKey && (e.key === '[' || e.key === '{')) {
        e.preventDefault()
        e.stopPropagation()
        useEditorStore.getState().cycleTab(-1)
        return
      }

      // --- Sidebar view switching ---
      if (mod && e.shiftKey && key === 'e') {
        e.preventDefault()
        e.stopPropagation()
        useLayoutStore.getState().showView('explorer')
        return
      }
      if (mod && e.shiftKey && key === 'g') {
        e.preventDefault()
        e.stopPropagation()
        useLayoutStore.getState().showView('git')
        return
      }
      if (mod && e.shiftKey && key === 't') {
        e.preventDefault()
        e.stopPropagation()
        useLayoutStore.getState().showView('tests')
        return
      }

      // --- Tab by index Cmd/Ctrl+1-9 ---
      if (mod && !e.shiftKey && !e.altKey) {
        const num = parseInt(e.key)
        if (num >= 1 && num <= 9) {
          e.preventDefault()
          e.stopPropagation()
          const { tabs } = useEditorStore.getState()
          if (tabs[num - 1]) useEditorStore.setState({ activePath: tabs[num - 1].path })
        }
      }
    }

    // capture phase — fires before Monaco's own key handlers
    window.addEventListener('keydown', handler, true)
    return () => window.removeEventListener('keydown', handler, true)
  }, [])
}
