import { create } from 'zustand'
import type { GitCommit, GitStatus } from '../types'

interface GitState {
  status: GitStatus | null
  commits: GitCommit[]
  branches: { current: string; all: string[] }
  commitMessage: string
  diffPath: string | null
  refresh: () => Promise<void>
  setCommitMessage: (m: string) => void
  stage: (path: string) => Promise<void>
  unstage: (path: string) => Promise<void>
  stageAll: () => Promise<void>
  commit: () => Promise<void>
  checkout: (name: string) => Promise<void>
  openDiff: (path: string | null) => void
}

export const useGitStore = create<GitState>((set, get) => ({
  status: null,
  commits: [],
  branches: { current: '', all: [] },
  commitMessage: '',
  diffPath: null,

  refresh: async () => {
    try {
      const status = (await window.api.git.status()) as GitStatus
      set({ status })
      if (status.isRepo) {
        const [commits, branches] = await Promise.all([
          window.api.git.log() as Promise<GitCommit[]>,
          window.api.git.branches() as Promise<{ current: string; all: string[] }>
        ])
        set({ commits, branches })
      } else {
        set({ commits: [], branches: { current: '', all: [] } })
      }
    } catch {
      set({ status: { isRepo: false, branch: '', ahead: 0, behind: 0, files: [] } })
    }
  },

  setCommitMessage: (commitMessage) => set({ commitMessage }),
  stage: async (path) => {
    await window.api.git.stage(path)
    await get().refresh()
  },
  unstage: async (path) => {
    await window.api.git.unstage(path)
    await get().refresh()
  },
  stageAll: async () => {
    await window.api.git.stageAll()
    await get().refresh()
  },
  commit: async () => {
    const msg = get().commitMessage.trim()
    if (!msg) return
    await window.api.git.commit(msg)
    set({ commitMessage: '' })
    await get().refresh()
  },
  checkout: async (name) => {
    await window.api.git.checkout(name)
    await get().refresh()
  },
  openDiff: (diffPath) => set({ diffPath })
}))
