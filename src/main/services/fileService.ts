import { promises as fs, readFileSync, statSync } from 'fs'
import { basename, dirname, join, resolve as resolvePath } from 'path'

export interface DirEntry {
  name: string
  path: string
  type: 'file' | 'dir'
}

const IGNORED = new Set(['.git', 'node_modules', '.DS_Store', 'out', 'dist'])

export async function readDir(dirPath: string): Promise<DirEntry[]> {
  const dirents = await fs.readdir(dirPath, { withFileTypes: true })
  const entries: DirEntry[] = []
  for (const d of dirents) {
    if (IGNORED.has(d.name)) continue
    entries.push({
      name: d.name,
      path: join(dirPath, d.name),
      type: d.isDirectory() ? 'dir' : 'file'
    })
  }
  // dirs first, then alphabetical
  entries.sort((a, b) => {
    if (a.type !== b.type) return a.type === 'dir' ? -1 : 1
    return a.name.localeCompare(b.name)
  })
  return entries
}

export async function readFile(filePath: string): Promise<string> {
  return fs.readFile(filePath, 'utf8')
}

export async function writeFile(filePath: string, content: string): Promise<void> {
  await fs.writeFile(filePath, content, 'utf8')
}

export async function createEntry(targetPath: string, type: 'file' | 'dir'): Promise<void> {
  if (type === 'dir') {
    await fs.mkdir(targetPath, { recursive: true })
  } else {
    await fs.mkdir(join(targetPath, '..'), { recursive: true })
    await fs.writeFile(targetPath, '', { flag: 'wx' })
  }
}

export async function renameEntry(oldPath: string, newPath: string): Promise<void> {
  await fs.rename(oldPath, newPath)
}

export async function deleteEntry(targetPath: string): Promise<void> {
  await fs.rm(targetPath, { recursive: true, force: true })
}

export function nameOf(p: string): string {
  return basename(p)
}

const RESOLVE_EXTS = [
  '.ts',
  '.tsx',
  '.d.ts',
  '.js',
  '.jsx',
  '.mjs',
  '.cjs',
  '.vue',
  '.json',
  '.css',
  '.scss',
  '.sass',
  '.less'
]

function isFile(p: string): boolean {
  try {
    return statSync(p).isFile()
  } catch {
    return false
  }
}

function isDir(p: string): boolean {
  try {
    return statSync(p).isDirectory()
  } catch {
    return false
  }
}

/** Resolve a path that may be missing its extension or be a directory. */
function resolveCandidate(p: string): string | null {
  if (isFile(p)) return p
  for (const ext of RESOLVE_EXTS) {
    if (isFile(p + ext)) return p + ext
  }
  if (isDir(p)) {
    const pkg = join(p, 'package.json')
    if (isFile(pkg)) {
      try {
        const json = JSON.parse(readFileSync(pkg, 'utf8'))
        const entry = json.types || json.typings || json.module || json.main
        if (entry) {
          const r = resolveCandidate(join(p, entry))
          if (r) return r
        }
      } catch {
        // ignore malformed package.json
      }
    }
    for (const ext of RESOLVE_EXTS) {
      if (isFile(join(p, 'index' + ext))) return join(p, 'index' + ext)
    }
  }
  return null
}

const MAX_FILES = 5000

export async function listFiles(root: string): Promise<string[]> {
  const results: string[] = []
  const walk = async (dir: string): Promise<void> => {
    if (results.length >= MAX_FILES) return
    try {
      const dirents = await fs.readdir(dir, { withFileTypes: true })
      for (const d of dirents) {
        if (IGNORED.has(d.name)) continue
        const p = join(dir, d.name)
        if (d.isDirectory()) {
          await walk(p)
        } else {
          results.push(p)
          if (results.length >= MAX_FILES) return
        }
      }
    } catch {
      // skip unreadable dirs
    }
  }
  await walk(root)
  return results
}

/**
 * Resolve an import/require specifier from a source file to an absolute path.
 * Handles relative paths and best-effort node_modules lookup. Returns null if
 * nothing matches (e.g. unresolvable bare module).
 */
export function resolveImport(fromFile: string, specifier: string): string | null {
  // strip query/hash sometimes present in css/url() or vite imports
  const spec = specifier.replace(/[?#].*$/, '')
  if (!spec) return null

  if (spec.startsWith('.') || spec.startsWith('/')) {
    const base = dirname(fromFile)
    return resolveCandidate(resolvePath(base, spec))
  }

  // bare specifier — walk up looking in node_modules
  let dir = dirname(fromFile)
  for (;;) {
    const candidate = join(dir, 'node_modules', spec)
    const r = resolveCandidate(candidate)
    if (r) return r
    const parent = dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return null
}
