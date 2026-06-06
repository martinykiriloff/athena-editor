import { BrowserWindow } from 'electron'
import {
  query,
  type CanUseTool,
  type PermissionResult,
  type SDKMessage,
  type SlashCommand
} from '@anthropic-ai/claude-agent-sdk'
import { getClaudeEnv } from './env'

// Events streamed to renderer over the 'claude:event' channel.
export type ClaudeEvent =
  | { kind: 'assistant'; text: string }
  | { kind: 'tool_use'; id: string; name: string; input: unknown }
  | { kind: 'permission'; id: string; toolName: string; input: unknown; title?: string }
  | { kind: 'result'; success: boolean; text: string; sessionId: string }
  | { kind: 'auth'; source: string; model: string }
  | { kind: 'error'; message: string }
  | { kind: 'done' }

class ClaudeService {
  private win: BrowserWindow | null = null
  private lastSessionId: string | undefined
  private abort: AbortController | null = null
  private pendingPermissions = new Map<string, (r: PermissionResult) => void>()

  attach(win: BrowserWindow): void {
    this.win = win
  }

  private send(ev: ClaudeEvent): void {
    if (this.win && !this.win.isDestroyed()) this.win.webContents.send('claude:event', ev)
  }

  resolvePermission(id: string, allow: boolean): void {
    const resolve = this.pendingPermissions.get(id)
    if (!resolve) return
    this.pendingPermissions.delete(id)
    resolve(
      allow
        ? { behavior: 'allow', updatedInput: undefined }
        : { behavior: 'deny', message: 'User denied this action.' }
    )
  }

  stop(): void {
    this.abort?.abort()
    this.abort = null
    for (const [, resolve] of this.pendingPermissions) {
      resolve({ behavior: 'deny', message: 'Aborted.' })
    }
    this.pendingPermissions.clear()
  }

  /** Fetch the full slash-command list. Spawns a throwaway session, reads the
   *  command list (available before any model turn), then aborts — no turn cost. */
  async listCommands(cwd: string): Promise<SlashCommand[]> {
    const ac = new AbortController()
    try {
      const env = await getClaudeEnv()
      const q = query({
        prompt: 'init',
        options: { cwd: cwd || process.cwd(), env, executable: 'node', abortController: ac }
      })
      const commands = await q.supportedCommands()
      ac.abort()
      return commands
    } catch {
      ac.abort()
      return []
    }
  }

  async run(prompt: string, cwd: string): Promise<void> {
    this.abort = new AbortController()
    const signal = this.abort.signal

    const canUseTool: CanUseTool = (toolName, input, opts) => {
      const id = opts.toolUseID || `${toolName}-${this.pendingPermissions.size}`
      return new Promise<PermissionResult>((resolve) => {
        this.pendingPermissions.set(id, resolve)
        this.send({ kind: 'permission', id, toolName, input, title: opts.title })
      })
    }

    try {
      // Real PATH (so the bundled CLI + node resolve) with API key stripped,
      // forcing the signed-in Claude account (subscription OAuth) — same as the
      // VS Code extension.
      const env = await getClaudeEnv()

      const response = query({
        prompt,
        options: {
          cwd,
          abortController: this.abort,
          canUseTool,
          env,
          executable: 'node',
          ...(this.lastSessionId ? { resume: this.lastSessionId } : {})
        }
      })

      for await (const msg of response as AsyncIterable<SDKMessage>) {
        if (signal.aborted) break
        this.handleMessage(msg)
      }
    } catch (err) {
      if (!signal.aborted) {
        this.send({ kind: 'error', message: err instanceof Error ? err.message : String(err) })
      }
    } finally {
      this.send({ kind: 'done' })
      this.abort = null
    }
  }

  private handleMessage(msg: SDKMessage): void {
    switch (msg.type) {
      case 'assistant': {
        const content = msg.message?.content ?? []
        for (const block of content as Array<{
          type: string
          text?: string
          id?: string
          name?: string
          input?: unknown
        }>) {
          if (block.type === 'text' && block.text) {
            this.send({ kind: 'assistant', text: block.text })
          } else if (block.type === 'tool_use') {
            this.send({
              kind: 'tool_use',
              id: block.id ?? '',
              name: block.name ?? '',
              input: block.input
            })
          }
        }
        break
      }
      case 'system': {
        if (msg.subtype === 'init') {
          this.send({ kind: 'auth', source: msg.apiKeySource, model: msg.model })
        }
        break
      }
      case 'result': {
        this.lastSessionId = msg.session_id
        const text = msg.subtype === 'success' ? msg.result : ''
        this.send({ kind: 'result', success: !msg.is_error, text, sessionId: msg.session_id })
        break
      }
      default:
        break
    }
  }
}

export const claudeService = new ClaudeService()
