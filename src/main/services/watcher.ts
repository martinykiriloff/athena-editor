import chokidar, { FSWatcher } from 'chokidar'
import { BrowserWindow } from 'electron'

export type FsChangeType = 'add' | 'addDir' | 'change' | 'unlink' | 'unlinkDir'

let watcher: FSWatcher | null = null

export function watchWorkspace(root: string, win: BrowserWindow): void {
  closeWatcher()
  watcher = chokidar.watch(root, {
    ignoreInitial: true,
    ignored: /(^|[/\\])(\.git|node_modules|out|dist|\.DS_Store)([/\\]|$)/,
    persistent: true,
    depth: 99
  })
  const emit = (type: FsChangeType) => (path: string) => {
    if (win.isDestroyed()) return
    win.webContents.send('fs:changed', { type, path })
  }
  watcher
    .on('add', emit('add'))
    .on('addDir', emit('addDir'))
    .on('change', emit('change'))
    .on('unlink', emit('unlink'))
    .on('unlinkDir', emit('unlinkDir'))
}

export function closeWatcher(): void {
  if (watcher) {
    void watcher.close()
    watcher = null
  }
}
