import { useEffect, useRef } from 'react'
import { Terminal as XTerm } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { LigaturesAddon } from '@xterm/addon-ligatures'
import '@xterm/xterm/css/xterm.css'
import { EDITOR_FONT, EDITOR_FONT_SIZE } from '../editor/theme'

let counter = 0

function Terminal(): React.JSX.Element {
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const container = containerRef.current
    if (!container) return
    const id = `term-${++counter}`

    const term = new XTerm({
      fontFamily: EDITOR_FONT,
      fontSize: EDITOR_FONT_SIZE,
      theme: { background: '#2B2B2B', foreground: '#A9B7C6', cursor: '#BBBBBB' },
      cursorBlink: true
    })
    const fit = new FitAddon()
    term.loadAddon(fit)
    term.open(container)
    term.loadAddon(new LigaturesAddon())
    fit.fit()

    void window.api.pty.create(id, term.cols, term.rows)

    const offData = window.api.pty.onData((p) => {
      if (p.id === id) term.write(p.data)
    })
    const offExit = window.api.pty.onExit((p) => {
      if (p.id === id) term.write('\r\n[process exited]\r\n')
    })
    const inputDisposable = term.onData((data) => {
      void window.api.pty.write(id, data)
    })

    const resize = (): void => {
      fit.fit()
      void window.api.pty.resize(id, term.cols, term.rows)
    }
    const observer = new ResizeObserver(resize)
    observer.observe(container)

    return () => {
      observer.disconnect()
      offData()
      offExit()
      inputDisposable.dispose()
      void window.api.pty.kill(id)
      term.dispose()
    }
  }, [])

  return <div className="terminal-host" ref={containerRef} />
}

export default Terminal
