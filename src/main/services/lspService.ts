import { ChildProcess, spawn } from 'child_process'
import { existsSync } from 'fs'
import { join } from 'path'
import { BrowserWindow, app } from 'electron'
import { is } from '@electron-toolkit/utils'

function serverModule(): string {
  const nmBase = is.dev
    ? join(app.getAppPath(), 'node_modules')
    : join(process.resourcesPath, 'app.asar.unpacked', 'node_modules')
  return join(nmBase, 'typescript-language-server/lib/cli.mjs')
}

// Mirror the ESLint resolution pattern: prefer workspace's own TypeScript.
function workspaceTsServerPath(rootPath: string): string | undefined {
  const candidate = join(rootPath, 'node_modules', 'typescript', 'lib', 'tsserver.js')
  return existsSync(candidate) ? candidate : undefined
}

export class LspService {
  private proc: ChildProcess | null = null
  private buf = ''
  private win: BrowserWindow | null = null
  private stopping = false

  start(win: BrowserWindow, rootPath: string): void {
    this.stop()
    this.win = win
    this.buf = ''
    this.stopping = false

    const args = [serverModule(), '--stdio']
    const tsPath = workspaceTsServerPath(rootPath)
    if (tsPath) args.push('--tsserver-path', tsPath)

    this.proc = spawn(process.execPath, args, {
      cwd: rootPath,
      env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' },
      stdio: ['pipe', 'pipe', 'pipe']
    })

    this.proc.stdout!.on('data', (chunk: Buffer) => {
      this.buf += chunk.toString('utf8')
      this.flush()
    })

    this.proc.stderr!.on('data', (d: Buffer) => {
      console.error('[LSP]', d.toString().trimEnd())
    })

    this.proc.on('exit', (code, signal) => {
      console.log('[LSP] exited', code, signal)
      if (!this.stopping && this.win && !this.win.isDestroyed()) {
        this.win.webContents.send('lsp:exit', { code, signal })
      }
      this.proc = null
    })
  }

  private flush(): void {
    for (;;) {
      const sep = this.buf.indexOf('\r\n\r\n')
      if (sep === -1) break
      const header = this.buf.slice(0, sep)
      const m = /Content-Length:\s*(\d+)/i.exec(header)
      if (!m) {
        this.buf = this.buf.slice(sep + 4)
        continue
      }
      const len = parseInt(m[1], 10)
      const bodyStart = sep + 4
      if (this.buf.length < bodyStart + len) break
      const body = this.buf.slice(bodyStart, bodyStart + len)
      this.buf = this.buf.slice(bodyStart + len)
      try {
        this.win?.webContents.send('lsp:message', JSON.parse(body))
      } catch {
        // malformed JSON — skip
      }
    }
  }

  send(msg: object): void {
    if (!this.proc?.stdin?.writable) return
    const body = JSON.stringify(msg)
    const frame = `Content-Length: ${Buffer.byteLength(body, 'utf8')}\r\n\r\n${body}`
    this.proc.stdin.write(frame, 'utf8')
  }

  stop(): void {
    this.stopping = true
    this.proc?.kill()
    this.proc = null
    this.buf = ''
    this.win = null
    this.stopping = false
  }
}

export const lspService = new LspService()
