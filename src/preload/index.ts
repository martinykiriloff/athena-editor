import { contextBridge, ipcRenderer } from 'electron'
import { electronAPI } from '@electron-toolkit/preload'

const api = {
  workspace: {
    open: (): Promise<string | null> => ipcRenderer.invoke('workspace:open'),
    current: (): Promise<string | null> => ipcRenderer.invoke('workspace:current')
  },
  fs: {
    readDir: (path: string) => ipcRenderer.invoke('fs:readDir', path),
    readFile: (path: string): Promise<string> => ipcRenderer.invoke('fs:readFile', path),
    writeFile: (path: string, content: string): Promise<void> =>
      ipcRenderer.invoke('fs:writeFile', path, content),
    create: (path: string, type: 'file' | 'dir'): Promise<void> =>
      ipcRenderer.invoke('fs:create', path, type),
    rename: (oldPath: string, newPath: string): Promise<void> =>
      ipcRenderer.invoke('fs:rename', oldPath, newPath),
    delete: (path: string): Promise<void> => ipcRenderer.invoke('fs:delete', path),
    resolveImport: (fromFile: string, specifier: string): Promise<string | null> =>
      ipcRenderer.invoke('fs:resolveImport', fromFile, specifier),
    listFiles: (): Promise<string[]> => ipcRenderer.invoke('fs:listFiles')
  },
  claude: {
    send: (prompt: string): Promise<void> => ipcRenderer.invoke('claude:send', prompt),
    abort: (): Promise<void> => ipcRenderer.invoke('claude:abort'),
    listCommands: () => ipcRenderer.invoke('claude:listCommands'),
    respondPermission: (id: string, allow: boolean): Promise<void> =>
      ipcRenderer.invoke('claude:permission-response', id, allow),
    onEvent: (cb: (ev: unknown) => void): (() => void) => {
      const listener = (_e: unknown, ev: unknown): void => cb(ev)
      ipcRenderer.on('claude:event', listener)
      return () => ipcRenderer.removeListener('claude:event', listener)
    }
  },
  pty: {
    create: (id: string, cols: number, rows: number): Promise<void> =>
      ipcRenderer.invoke('pty:create', id, cols, rows),
    write: (id: string, data: string): Promise<void> => ipcRenderer.invoke('pty:write', id, data),
    resize: (id: string, cols: number, rows: number): Promise<void> =>
      ipcRenderer.invoke('pty:resize', id, cols, rows),
    kill: (id: string): Promise<void> => ipcRenderer.invoke('pty:kill', id),
    onData: (cb: (payload: { id: string; data: string }) => void): (() => void) => {
      const listener = (_e: unknown, payload: { id: string; data: string }): void => cb(payload)
      ipcRenderer.on('pty:data', listener)
      return () => ipcRenderer.removeListener('pty:data', listener)
    },
    onExit: (cb: (payload: { id: string }) => void): (() => void) => {
      const listener = (_e: unknown, payload: { id: string }): void => cb(payload)
      ipcRenderer.on('pty:exit', listener)
      return () => ipcRenderer.removeListener('pty:exit', listener)
    }
  },
  git: {
    status: () => ipcRenderer.invoke('git:status'),
    stage: (path: string): Promise<void> => ipcRenderer.invoke('git:stage', path),
    unstage: (path: string): Promise<void> => ipcRenderer.invoke('git:unstage', path),
    stageAll: (): Promise<void> => ipcRenderer.invoke('git:stageAll'),
    commit: (message: string): Promise<void> => ipcRenderer.invoke('git:commit', message),
    branches: () => ipcRenderer.invoke('git:branches'),
    checkout: (name: string): Promise<void> => ipcRenderer.invoke('git:checkout', name),
    log: () => ipcRenderer.invoke('git:log'),
    diff: (absPath: string) => ipcRenderer.invoke('git:diff', absPath)
  },
  eslint: {
    lint: (filePath: string, content: string) =>
      ipcRenderer.invoke('eslint:lint', filePath, content)
  },
  jest: {
    run: (file?: string): Promise<void> => ipcRenderer.invoke('jest:run', file),
    stop: (): Promise<void> => ipcRenderer.invoke('jest:stop'),
    onEvent: (cb: (ev: unknown) => void): (() => void) => {
      const listener = (_e: unknown, ev: unknown): void => cb(ev)
      ipcRenderer.on('jest:event', listener)
      return () => ipcRenderer.removeListener('jest:event', listener)
    }
  },
  onFsChanged: (cb: (payload: { type: string; path: string }) => void): (() => void) => {
    const listener = (_e: unknown, payload: { type: string; path: string }): void => cb(payload)
    ipcRenderer.on('fs:changed', listener)
    return () => ipcRenderer.removeListener('fs:changed', listener)
  },
  lsp: {
    start: (rootPath: string): Promise<void> => ipcRenderer.invoke('lsp:start', rootPath),
    stop: (): Promise<void> => ipcRenderer.invoke('lsp:stop'),
    send: (msg: object): void => ipcRenderer.send('lsp:send', msg),
    onMessage: (cb: (msg: Record<string, unknown>) => void): (() => void) => {
      const listener = (_e: unknown, msg: Record<string, unknown>): void => cb(msg)
      ipcRenderer.on('lsp:message', listener)
      return () => ipcRenderer.removeListener('lsp:message', listener)
    },
    onExit: (cb: (info: { code: number | null; signal: string | null }) => void): (() => void) => {
      const listener = (_e: unknown, info: { code: number | null; signal: string | null }): void =>
        cb(info)
      ipcRenderer.on('lsp:exit', listener)
      return () => ipcRenderer.removeListener('lsp:exit', listener)
    }
  }
}

if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld('electron', electronAPI)
    contextBridge.exposeInMainWorld('api', api)
  } catch (error) {
    console.error(error)
  }
} else {
  // @ts-ignore (define in dts)
  window.electron = electronAPI
  // @ts-ignore (define in dts)
  window.api = api
}

export type AthenaApi = typeof api
