import { promises as fs } from 'fs'
import { relative } from 'path'
import simpleGit, { type SimpleGit } from 'simple-git'

export interface GitFile {
  path: string
  /** index (staged) status code, e.g. M A D ? */
  index: string
  /** working tree status code */
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

function git(root: string): SimpleGit {
  return simpleGit(root)
}

export async function status(root: string): Promise<GitStatus> {
  const g = git(root)
  const isRepo = await g.checkIsRepo().catch(() => false)
  if (!isRepo) {
    return { isRepo: false, branch: '', ahead: 0, behind: 0, files: [] }
  }
  const s = await g.status()
  const files: GitFile[] = s.files.map((f) => ({
    path: f.path,
    index: f.index.trim(),
    working: f.working_dir.trim(),
    staged: f.index.trim() !== '' && f.index.trim() !== '?'
  }))
  return {
    isRepo: true,
    branch: s.current ?? '',
    ahead: s.ahead,
    behind: s.behind,
    files
  }
}

export async function stage(root: string, path: string): Promise<void> {
  await git(root).add(path)
}

export async function unstage(root: string, path: string): Promise<void> {
  await git(root).reset(['--', path])
}

export async function stageAll(root: string): Promise<void> {
  await git(root).add('.')
}

export async function commit(root: string, message: string): Promise<void> {
  await git(root).commit(message)
}

export async function branches(root: string): Promise<{ current: string; all: string[] }> {
  const b = await git(root).branchLocal()
  return { current: b.current, all: b.all }
}

export async function checkout(root: string, name: string): Promise<void> {
  await git(root).checkout(name)
}

export async function log(root: string, limit = 200): Promise<GitCommit[]> {
  // %x1f = unit separator between fields, %x1e = record separator between commits
  const fmt = ['%H', '%P', '%s', '%an', '%ad', '%D'].join('%x1f') + '%x1e'
  const raw = await git(root).raw(['log', `--pretty=format:${fmt}`, '--date=short', `-n${limit}`])
  return raw
    .split('\x1e')
    .map((r) => r.trim())
    .filter(Boolean)
    .map((rec) => {
      const [hash, parents, subject, author, date, refs] = rec.split('\x1f')
      return {
        hash,
        parents: parents ? parents.split(' ').filter(Boolean) : [],
        subject,
        author,
        date,
        refs: refs ?? ''
      }
    })
}

/** Returns HEAD version and working version of a file for a diff view. */
export async function diff(
  root: string,
  absPath: string
): Promise<{ original: string; modified: string }> {
  const rel = relative(root, absPath).split('\\').join('/')
  const original = await git(root)
    .show([`HEAD:${rel}`])
    .catch(() => '')
  const modified = await fs.readFile(absPath, 'utf8').catch(() => '')
  return { original, modified }
}
