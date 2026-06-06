import { BrowserWindow } from 'electron'
import * as os from 'os'
import * as pty from 'node-pty'

interface Session {
  proc: pty.IPty
}

class PtyService {
  private win: BrowserWindow | null = null
  private sessions = new Map<string, Session>()

  attach(win: BrowserWindow): void {
    this.win = win
  }

  private shell(): string {
    if (process.platform === 'win32') return process.env.COMSPEC || 'powershell.exe'
    return process.env.SHELL || '/bin/zsh'
  }

  create(id: string, cwd: string, cols: number, rows: number): void {
    if (this.sessions.has(id)) return
    const proc = pty.spawn(this.shell(), [], {
      name: 'xterm-color',
      cols: cols || 80,
      rows: rows || 24,
      cwd: cwd || os.homedir(),
      env: process.env as Record<string, string>
    })
    proc.onData((data) => {
      if (this.win && !this.win.isDestroyed()) {
        this.win.webContents.send('pty:data', { id, data })
      }
    })
    proc.onExit(() => {
      this.sessions.delete(id)
      if (this.win && !this.win.isDestroyed()) {
        this.win.webContents.send('pty:exit', { id })
      }
    })
    this.sessions.set(id, { proc })
  }

  write(id: string, data: string): void {
    this.sessions.get(id)?.proc.write(data)
  }

  resize(id: string, cols: number, rows: number): void {
    try {
      this.sessions.get(id)?.proc.resize(cols, rows)
    } catch {
      // resize on a dead pty throws; ignore
    }
  }

  kill(id: string): void {
    const s = this.sessions.get(id)
    if (!s) return
    s.proc.kill()
    this.sessions.delete(id)
  }

  killAll(): void {
    for (const [, s] of this.sessions) s.proc.kill()
    this.sessions.clear()
  }
}

export const ptyService = new PtyService()
