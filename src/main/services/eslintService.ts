import { createRequire } from 'module'
import { join } from 'path'

export interface LintMessage {
  ruleId: string | null
  severity: number // 1 = warning, 2 = error
  message: string
  line: number
  column: number
  endLine?: number
  endColumn?: number
}

// Cache one ESLint instance per workspace root.
const cache = new Map<string, unknown>()

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function loadESLintClass(root: string): any {
  // Prefer the workspace's own ESLint (so its plugins/config resolve), fall back to ours.
  try {
    const req = createRequire(join(root, 'noop.js'))
    return req('eslint').ESLint
  } catch {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    return require('eslint').ESLint
  }
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function getInstance(root: string): any {
  if (cache.has(root)) return cache.get(root)
  const ESLint = loadESLintClass(root)
  const instance = new ESLint({ cwd: root, errorOnUnmatchedPattern: false })
  cache.set(root, instance)
  return instance
}

export function invalidate(root: string): void {
  cache.delete(root)
}

export async function lintText(
  root: string,
  filePath: string,
  content: string
): Promise<LintMessage[]> {
  try {
    const eslint = getInstance(root)
    // Skip files ESLint is configured to ignore.
    if (await eslint.isPathIgnored(filePath)) return []
    const results = await eslint.lintText(content, { filePath })
    const messages = results[0]?.messages ?? []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    return messages.map((m: any) => ({
      ruleId: m.ruleId ?? null,
      severity: m.severity,
      message: m.message,
      line: m.line ?? 1,
      column: m.column ?? 1,
      endLine: m.endLine,
      endColumn: m.endColumn
    }))
  } catch {
    // No ESLint config / parser error / unsupported file — report nothing.
    return []
  }
}
