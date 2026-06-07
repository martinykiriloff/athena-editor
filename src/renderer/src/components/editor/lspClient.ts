type Handler = (params: unknown) => void

interface Pending {
  resolve: (result: unknown) => void
  reject: (err: unknown) => void
}

export class LspClient {
  private nextId = 1
  private pending = new Map<number, Pending>()
  private notifications = new Map<string, Handler[]>()
  private readyCallbacks: Array<() => void> = []
  private _ready = false

  constructor() {
    window.api.lsp.onMessage((msg: Record<string, unknown>) => this.dispatch(msg))
  }

  get ready(): boolean {
    return this._ready
  }

  reset(): void {
    this._ready = false
    this.pending.forEach((p) => p.reject(new Error('LSP restarting')))
    this.pending.clear()
  }

  onReady(cb: () => void): void {
    if (this._ready) cb()
    else this.readyCallbacks.push(cb)
  }

  private dispatch(msg: Record<string, unknown>): void {
    if ('id' in msg && ('result' in msg || 'error' in msg)) {
      const p = this.pending.get(msg.id as number)
      if (p) {
        this.pending.delete(msg.id as number)
        if ('error' in msg) p.reject(msg.error)
        else p.resolve(msg.result)
      }
    } else if (typeof msg.method === 'string' && !('id' in msg)) {
      const handlers = this.notifications.get(msg.method) ?? []
      for (const h of handlers) h(msg.params)
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
    const cbs = this.readyCallbacks.splice(0)
    for (const cb of cbs) cb()
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
