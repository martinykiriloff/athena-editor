import { exec } from 'child_process'
import { homedir } from 'os'

// GUI-launched apps on macOS/Linux inherit a stripped PATH that omits nvm,
// Homebrew, ~/.local/bin, etc. The Claude Code CLI (and the node runtime that
// runs it) live there, and the OAuth credentials in the Keychain are read by
// that CLI — so without a real PATH the SDK subprocess can't start. We resolve
// the user's login-shell PATH once and reuse it.

let cached: Record<string, string> | null = null

const FALLBACK_DIRS = [
  '/opt/homebrew/bin',
  '/usr/local/bin',
  '/usr/bin',
  '/bin',
  '/usr/sbin',
  '/sbin',
  `${homedir()}/.local/bin`
]

function loginShellPath(): Promise<string | null> {
  return new Promise((resolve) => {
    const shell = process.env.SHELL || '/bin/zsh'
    // -i -l -c so rc files (which set up nvm/asdf/path) are sourced.
    exec(`${shell} -ilc 'printf "%s" "$PATH"'`, { timeout: 5000 }, (err, stdout) => {
      if (err || !stdout.trim()) return resolve(null)
      resolve(stdout.trim())
    })
  })
}

export async function getShellEnv(): Promise<Record<string, string>> {
  if (cached) return cached
  const env: Record<string, string> = { ...(process.env as Record<string, string>) }

  if (process.platform !== 'win32') {
    const resolved = await loginShellPath()
    const parts = new Set<string>()
    if (resolved)
      resolved.split(':').forEach((p) => p && parts.add(p))
      // Keep whatever the GUI already had, then guarantee the fallbacks.
    ;(env.PATH || '').split(':').forEach((p) => p && parts.add(p))
    FALLBACK_DIRS.forEach((p) => parts.add(p))
    env.PATH = Array.from(parts).join(':')
  }

  cached = env
  return env
}

/**
 * Environment for the Claude SDK subprocess: real PATH, but with any
 * ANTHROPIC_API_KEY removed so the CLI uses the signed-in Claude account
 * (subscription OAuth) rather than falling back to API-key billing.
 */
export async function getClaudeEnv(): Promise<Record<string, string>> {
  const env = { ...(await getShellEnv()) }
  delete env.ANTHROPIC_API_KEY
  delete env.ANTHROPIC_AUTH_TOKEN
  return env
}
