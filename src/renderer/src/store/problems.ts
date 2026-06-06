import { create } from 'zustand'
import type { LintMessage } from '../types'

interface ProblemsState {
  byFile: Record<string, LintMessage[]>
  setForFile: (path: string, messages: LintMessage[]) => void
  clearFile: (path: string) => void
  total: () => number
}

export const useProblemsStore = create<ProblemsState>((set, get) => ({
  byFile: {},
  setForFile: (path, messages) =>
    set((s) => {
      const byFile = { ...s.byFile }
      if (messages.length === 0) delete byFile[path]
      else byFile[path] = messages
      return { byFile }
    }),
  clearFile: (path) =>
    set((s) => {
      const byFile = { ...s.byFile }
      delete byFile[path]
      return { byFile }
    }),
  total: () => Object.values(get().byFile).reduce((n, m) => n + m.length, 0)
}))
