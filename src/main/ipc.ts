import { BrowserWindow, dialog, ipcMain } from 'electron'
import {
  createEntry,
  deleteEntry,
  listFiles,
  readDir,
  readFile,
  renameEntry,
  resolveImport,
  writeFile
} from './services/fileService'
import { closeWatcher, watchWorkspace } from './services/watcher'
import { claudeService } from './services/claudeService'
import { ptyService } from './services/ptyService'
import { jestService } from './services/jestService'
import * as git from './services/gitService'
import * as eslint from './services/eslintService'
import { lspService } from './services/lspService'

let currentRoot: string | null = null
const requireRoot = (): string => {
  if (!currentRoot) throw new Error('No folder open')
  return currentRoot
}

export function registerIpc(win: BrowserWindow): void {
  claudeService.attach(win)
  ptyService.attach(win)
  jestService.attach(win)

  // ---- Workspace ----
  ipcMain.handle('workspace:open', async () => {
    const result = await dialog.showOpenDialog(win, { properties: ['openDirectory'] })
    if (result.canceled || result.filePaths.length === 0) return null
    currentRoot = result.filePaths[0]
    eslint.invalidate(currentRoot)
    watchWorkspace(currentRoot, win)
    return currentRoot
  })
  ipcMain.handle('workspace:current', () => currentRoot)

  // ---- File system ----
  ipcMain.handle('fs:readDir', (_e, path: string) => readDir(path))
  ipcMain.handle('fs:readFile', (_e, path: string) => readFile(path))
  ipcMain.handle('fs:writeFile', (_e, path: string, content: string) => writeFile(path, content))
  ipcMain.handle('fs:create', (_e, path: string, type: 'file' | 'dir') => createEntry(path, type))
  ipcMain.handle('fs:rename', (_e, oldPath: string, newPath: string) =>
    renameEntry(oldPath, newPath)
  )
  ipcMain.handle('fs:delete', (_e, path: string) => deleteEntry(path))
  ipcMain.handle('fs:resolveImport', (_e, fromFile: string, specifier: string) =>
    resolveImport(fromFile, specifier)
  )
  ipcMain.handle('fs:listFiles', () => listFiles(requireRoot()))

  // ---- Claude ----
  ipcMain.handle('claude:send', (_e, prompt: string) => {
    if (!currentRoot) {
      win.webContents.send('claude:event', {
        kind: 'error',
        message: 'Open a folder before chatting with Claude.'
      })
      return
    }
    void claudeService.run(prompt, currentRoot)
  })
  ipcMain.handle('claude:abort', () => claudeService.stop())
  ipcMain.handle('claude:listCommands', () => claudeService.listCommands(currentRoot ?? ''))
  ipcMain.handle('claude:permission-response', (_e, id: string, allow: boolean) =>
    claudeService.resolvePermission(id, allow)
  )

  // ---- Terminal (pty) ----
  ipcMain.handle('pty:create', (_e, id: string, cols: number, rows: number) =>
    ptyService.create(id, currentRoot ?? '', cols, rows)
  )
  ipcMain.handle('pty:write', (_e, id: string, data: string) => ptyService.write(id, data))
  ipcMain.handle('pty:resize', (_e, id: string, cols: number, rows: number) =>
    ptyService.resize(id, cols, rows)
  )
  ipcMain.handle('pty:kill', (_e, id: string) => ptyService.kill(id))

  // ---- Git ----
  ipcMain.handle('git:status', () => git.status(requireRoot()))
  ipcMain.handle('git:stage', (_e, path: string) => git.stage(requireRoot(), path))
  ipcMain.handle('git:unstage', (_e, path: string) => git.unstage(requireRoot(), path))
  ipcMain.handle('git:stageAll', () => git.stageAll(requireRoot()))
  ipcMain.handle('git:commit', (_e, message: string) => git.commit(requireRoot(), message))
  ipcMain.handle('git:branches', () => git.branches(requireRoot()))
  ipcMain.handle('git:checkout', (_e, name: string) => git.checkout(requireRoot(), name))
  ipcMain.handle('git:log', () => git.log(requireRoot()))
  ipcMain.handle('git:diff', (_e, absPath: string) => git.diff(requireRoot(), absPath))

  // ---- ESLint ----
  ipcMain.handle('eslint:lint', (_e, filePath: string, content: string) =>
    eslint.lintText(requireRoot(), filePath, content)
  )

  // ---- Jest ----
  ipcMain.handle('jest:run', (_e, file?: string) => jestService.run(requireRoot(), file))
  ipcMain.handle('jest:stop', () => jestService.stop())

  // ---- LSP ----
  ipcMain.handle('lsp:start', (_e, rootPath: string) => lspService.start(win, rootPath))
  ipcMain.on('lsp:send', (_e, msg: object) => lspService.send(msg))
}

export function disposeIpc(): void {
  closeWatcher()
  ptyService.killAll()
  jestService.stop()
  lspService.stop()
}
