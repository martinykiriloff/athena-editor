// KeyRecorder.swift — records a single key combo from the user.

@preconcurrency import AppKit

@Observable
@MainActor
final class KeyRecorder {

    var recordingFor: KeyAction? = nil

    @ObservationIgnored private var eventMonitor: Any? = nil
    @ObservationIgnored private var onCommit: ((KeyAction, KeyCombo?) -> Void)?

    // MARK: API

    func start(for action: KeyAction, onCommit: @escaping (KeyAction, KeyCombo?) -> Void) {
        stop()
        self.onCommit = onCommit
        recordingFor  = action
        eventMonitor  = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Extract Sendable primitives before entering MainActor context so
            // NSEvent itself never crosses a @Sendable / actor boundary.
            let keyCode = event.keyCode
            let modRaw  = event.modifierFlags.rawValue
            let chars   = event.charactersIgnoringModifiers ?? ""
            // assumeIsolated returns Bool (Sendable) — no NSEvent in result type.
            let consume = MainActor.assumeIsolated {
                self?.processKey(keyCode: keyCode, modRaw: modRaw, chars: chars) ?? false
            }
            return consume ? nil : event
        }
    }

    func stop() {
        if let m = eventMonitor { NSEvent.removeMonitor(m) }
        eventMonitor = nil
        recordingFor = nil
        onCommit     = nil
    }

    // MARK: Private

    private func processKey(keyCode: UInt16, modRaw: UInt, chars: String) -> Bool {
        defer { stop() }
        guard let action = recordingFor else { return false }

        switch keyCode {
        case 53:         // Escape — cancel
            return true  // consume, but no commit
        case 51, 117:    // Delete / Forward Delete — clear binding
            onCommit?(action, nil)
            return true
        default:
            if let combo = KeyCombo.from(keyCode: keyCode, modRaw: modRaw, chars: chars) {
                onCommit?(action, combo)
                return true
            }
            return false  // unrecognised — pass through
        }
    }
}
