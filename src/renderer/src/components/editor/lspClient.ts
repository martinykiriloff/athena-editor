type Handler = (params: unknown) => void
type RequestHandler = (params: unknown) => unknown | Promise<unknown>

interface Pending {
  resolve: (result: unknown) => void
  reject: (err: unknown) => void
}

// Exponential backoff delays (ms), capped at 30 s.
const RESTART_DELAYS = [1_000, 2_000, 4_000, 8_000, 16_000, 30_000]

export class LspClient {
  private nextId = 1
  private pending = new Map<number, Pending>()
  private notifications = new Map<string, Handler[]>()
  private requests = new Map<string, RequestHandler>()
  // Permanent listeners — survive restarts so models re-sync on every ready.
  private readyListeners: Array<() => void> = []
  private _ready = false
  private _root: string | null = null
  private _restartCount = 0
  private _restartTimer: ReturnType<typeof setTimeout> | null = null

  constructor() {
    window.api.lsp.onMessage((msg: Record<string, unknown>) => this.dispatch(msg))
    window.api.lsp.onExit(() => this.handleExit())
  }

  get ready(): boolean {
    return this._ready
  }

  private handleExit(): void {
    this._ready = false
    this.pending.forEach((p) => p.reject(new Error('LSP restarting')))
    this.pending.clear()
    if (this._root) this.scheduleRestart(this._root)
  }

  private scheduleRestart(root: string): void {
    if (this._restartTimer) return
    const delay = RESTART_DELAYS[Math.min(this._restartCount, RESTART_DELAYS.length - 1)]
    this._restartCount++
    this._restartTimer = setTimeout(async () => {
      this._restartTimer = null
      if (this._root !== root) return
      try {
        await window.api.lsp.start(root)
        await this.initialize(root)
      } catch (err) {
        console.error('[LSP] restart failed', err)
        if (this._root === root) this.scheduleRestart(root)
      }
    }, delay)
  }

  reset(): void {
    this._ready = false
    this._root = null
    this._restartCount = 0
    if (this._restartTimer) {
      clearTimeout(this._restartTimer)
      this._restartTimer = null
    }
    this.pending.forEach((p) => p.reject(new Error('LSP reset')))
    this.pending.clear()
  }

  onReady(cb: () => void): void {
    if (this._ready) cb()
    else this.readyListeners.push(cb)
  }

  private dispatch(msg: Record<string, unknown>): void {
    if ('id' in msg && typeof msg.method === 'string') {
      this.handleServerRequest(msg.id, msg.method, msg.params)
    } else if ('id' in msg && ('result' in msg || 'error' in msg)) {
      const p = this.pending.get(msg.id as number)
      if (p) {
        this.pending.delete(msg.id as number)
        if ('error' in msg) p.reject(msg.error)
        else p.resolve(msg.result)
      }
    } else if (typeof msg.method === 'string') {
      const handlers = this.notifications.get(msg.method) ?? []
      for (const h of handlers) h(msg.params)
    }
  }

  private handleServerRequest(id: unknown, method: string, params: unknown): void {
    const handler = this.requests.get(method)
    const respond = (result: unknown, error?: unknown): void => {
      const response: Record<string, unknown> = { jsonrpc: '2.0', id }
      if (error !== undefined) response.error = error
      else response.result = result ?? null
      window.api.lsp.send(response)
    }
    if (handler) {
      Promise.resolve(handler(params))
        .then((r) => respond(r))
        .catch((err) => respond(null, { code: -32000, message: String(err) }))
    } else {
      respond(null)
    }
  }

  request<T>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject })
      window.api.lsp.send({ jsonrpc: '2.0', id, method, params })
    })
  }

  notify(method: string, params: unknown): void {
    window.api.lsp.send({ jsonrpc: '2.0', method, params })
  }

  onNotification(method: string, handler: Handler): () => void {
    const arr = this.notifications.get(method) ?? []
    arr.push(handler)
    this.notifications.set(method, arr)
    return () => {
      const cur = this.notifications.get(method) ?? []
      const i = cur.indexOf(handler)
      if (i >= 0) cur.splice(i, 1)
    }
  }

  async initialize(rootPath: string): Promise<void> {
    this._root = rootPath
    const rootUri = `file://${rootPath}`
    await this.request('initialize', {
      processId: null,
      clientInfo: { name: 'project-zeus', version: '1.0.0' },
      rootUri,
      capabilities: {
        textDocument: {
          synchronization: {
            dynamicRegistration: false,
            willSave: false,
            didSave: false,
            willSaveWaitUntil: false
          },
          completion: {
            dynamicRegistration: false,
            completionItem: {
              snippetSupport: true,
              documentationFormat: ['markdown', 'plaintext'],
              deprecatedSupport: true,
              resolveSupport: { properties: ['documentation', 'detail', 'additionalTextEdits'] }
            },
            contextSupport: true
          },
          hover: {
            dynamicRegistration: false,
            contentFormat: ['markdown', 'plaintext']
          },
          signatureHelp: {
            dynamicRegistration: false,
            signatureInformation: {
              documentationFormat: ['markdown', 'plaintext'],
              parameterInformation: { labelOffsetSupport: true }
            }
          },
          definition: { dynamicRegistration: false, linkSupport: false },
          references: { dynamicRegistration: false },
          implementation: { dynamicRegistration: false, linkSupport: false },
          documentSymbol: {
            dynamicRegistration: false,
            hierarchicalDocumentSymbolSupport: true
          },
          publishDiagnostics: { relatedInformation: true }
        },
        workspace: {
          symbol: { dynamicRegistration: false },
          workspaceFolders: true
        }
      },
      workspaceFolders: [{ uri: rootUri, name: rootPath.split('/').pop() ?? 'workspace' }]
    })
    this.notify('initialized', {})
    this._ready = true
    this._restartCount = 0
    // Permanent listeners — call but do not splice; they fire on every (re-)initialization.
    for (const cb of this.readyListeners) cb()
  }

  openDocument(uri: string, languageId: string, version: number, text: string): void {
    this.notify('textDocument/didOpen', {
      textDocument: { uri, languageId, version, text }
    })
  }

  changeDocument(uri: string, version: number, text: string): void {
    this.notify('textDocument/didChange', {
      textDocument: { uri, version },
      contentChanges: [{ text }]
    })
  }

  closeDocument(uri: string): void {
    this.notify('textDocument/didClose', { textDocument: { uri } })
  }
}

export const lspClient = new LspClient()
