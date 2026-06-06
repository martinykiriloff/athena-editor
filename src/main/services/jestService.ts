import { BrowserWindow } from 'electron'
import { spawn, type ChildProcess } from 'child_process'
import { existsSync } from 'fs'
import { join } from 'path'

export interface TestCase {
  title: string
  ancestors: string[]
  status: string // passed | failed | skipped | pending | todo
  failureMessages: string[]
}

export interface TestFile {
  name: string
  status: string
  tests: TestCase[]
}

export interface JestReport {
  success: boolean
  numPassed: number
  numFailed: number
  files: TestFile[]
}

export type JestEvent =
  | { kind: 'start' }
  | { kind: 'result'; report: JestReport }
  | { kind: 'error'; message: string }
  | { kind: 'done' }

class JestService {
  private win: BrowserWindow | null = null
  private proc: ChildProcess | null = null

  attach(win: BrowserWindow): void {
    this.win = win
  }

  private send(ev: JestEvent): void {
    if (this.win && !this.win.isDestroyed()) this.win.webContents.send('jest:event', ev)
  }

  private resolveBin(root: string): { cmd: string; baseArgs: string[] } {
    const local = join(
      root,
      'node_modules',
      '.bin',
      process.platform === 'win32' ? 'jest.cmd' : 'jest'
    )
    if (existsSync(local)) return { cmd: local, baseArgs: [] }
    return { cmd: process.platform === 'win32' ? 'npx.cmd' : 'npx', baseArgs: ['jest'] }
  }

  run(root: string, file?: string): void {
    this.stop()
    this.send({ kind: 'start' })

    const { cmd, baseArgs } = this.resolveBin(root)
    const args = [...baseArgs, '--json', '--testLocationInResults', '--ci']
    if (file) args.push(file)

    let stdout = ''
    let stderr = ''
    const proc = spawn(cmd, args, { cwd: root, env: process.env })
    this.proc = proc

    proc.stdout.on('data', (d) => (stdout += d.toString()))
    proc.stderr.on('data', (d) => (stderr += d.toString()))

    proc.on('error', (err) => {
      this.proc = null
      this.send({ kind: 'error', message: err.message })
      this.send({ kind: 'done' })
    })

    proc.on('close', () => {
      this.proc = null
      const json = this.extractJson(stdout)
      if (!json) {
        this.send({
          kind: 'error',
          message: stderr.trim() || 'Jest produced no parseable output.'
        })
        this.send({ kind: 'done' })
        return
      }
      try {
        this.send({ kind: 'result', report: this.parse(json) })
      } catch (e) {
        this.send({ kind: 'error', message: e instanceof Error ? e.message : String(e) })
      }
      this.send({ kind: 'done' })
    })
  }

  stop(): void {
    this.proc?.kill()
    this.proc = null
  }

  private extractJson(out: string): string | null {
    const start = out.indexOf('{')
    const end = out.lastIndexOf('}')
    if (start === -1 || end === -1 || end < start) return null
    return out.slice(start, end + 1)
  }

  private parse(json: string): JestReport {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r: any = JSON.parse(json)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const files: TestFile[] = (r.testResults ?? []).map((tr: any) => ({
      name: tr.name,
      status: tr.status,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      tests: (tr.assertionResults ?? []).map((a: any) => ({
        title: a.title,
        ancestors: a.ancestorTitles ?? [],
        status: a.status,
        failureMessages: a.failureMessages ?? []
      }))
    }))
    return {
      success: Boolean(r.success),
      numPassed: r.numPassedTests ?? 0,
      numFailed: r.numFailedTests ?? 0,
      files
    }
  }
}

export const jestService = new JestService()
