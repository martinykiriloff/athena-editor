export interface DirEntry {
  name: string
  path: string
  type: 'file' | 'dir'
}

export type ClaudeEvent =
  | { kind: 'assistant'; text: string }
  | { kind: 'tool_use'; id: string; name: string; input: unknown }
  | { kind: 'permission'; id: string; toolName: string; input: unknown; title?: string }
  | { kind: 'result'; success: boolean; text: string; sessionId: string }
  | { kind: 'auth'; source: string; model: string }
  | { kind: 'error'; message: string }
  | { kind: 'done' }

export type SidebarView = 'explorer' | 'git' | 'tests'

export type PanelTab = 'terminal' | 'problems' | 'tests'

export interface GitFile {
  path: string
  index: string
  working: string
  staged: boolean
}

export interface GitStatus {
  isRepo: boolean
  branch: string
  ahead: number
  behind: number
  files: GitFile[]
}

export interface GitCommit {
  hash: string
  parents: string[]
  subject: string
  author: string
  date: string
  refs: string
}

export interface LintMessage {
  ruleId: string | null
  severity: number
  message: string
  line: number
  column: number
  endLine?: number
  endColumn?: number
}

export interface TestCase {
  title: string
  ancestors: string[]
  status: string
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

export interface OpenTab {
  path: string
  name: string
  content: string
  dirty: boolean
}

export interface ChatMessage {
  id: string
  role: 'user' | 'assistant' | 'tool' | 'error'
  text: string
}

export interface SlashCmd {
  name: string
  description: string
  argumentHint: string
  aliases?: string[]
}

export interface PendingPermission {
  id: string
  toolName: string
  input: unknown
  title?: string
}
