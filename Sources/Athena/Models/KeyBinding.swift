// KeyBinding.swift — bindable actions, key combos, and VS Code defaults.

@preconcurrency import AppKit

// MARK: - KeyAction

enum KeyAction: String, Codable, CaseIterable, Sendable {
    // File
    case saveFile           = "workbench.action.files.save"
    case newFile            = "workbench.action.files.newUntitledFile"
    case closeTab           = "workbench.action.closeActiveEditor"
    // View
    case toggleSidebar      = "workbench.action.toggleSidebarVisibility"
    case toggleTerminal     = "workbench.action.terminal.toggleTerminal"
    case showExplorer       = "workbench.view.explorer"
    case showSourceControl  = "workbench.view.scm"
    case showSearch         = "workbench.view.search"
    case showDatabase       = "workbench.view.database"
    case showClaude         = "workbench.view.claude"
    // Navigation
    case quickOpen          = "workbench.action.quickOpen"
    case commandPalette     = "workbench.action.showCommands"
    case nextTab            = "workbench.action.nextEditor"
    case previousTab        = "workbench.action.previousEditor"
    case goToLine           = "workbench.action.gotoLine"
    // Editor
    case findInFile         = "actions.find"
    case findAndReplace     = "editor.action.startFindReplaceAction"
    case toggleComment      = "editor.action.commentLine"
    case indentLine         = "editor.action.indentLines"
    case outdentLine        = "editor.action.outdentLines"
    case selectNextOccurrence = "editor.action.addSelectionToNextFindMatch"
    // Zoom
    case zoomIn             = "workbench.action.zoomIn"
    case zoomOut            = "workbench.action.zoomOut"
    case resetZoom          = "workbench.action.zoomReset"

    var displayName: String {
        switch self {
        case .saveFile:          return "Save File"
        case .newFile:           return "New File"
        case .closeTab:          return "Close Editor"
        case .toggleSidebar:     return "Toggle Sidebar"
        case .toggleTerminal:    return "Toggle Terminal"
        case .showExplorer:      return "Show Explorer"
        case .showSourceControl: return "Show Source Control"
        case .showSearch:        return "Show Search"
        case .showDatabase:      return "Show DB Connections"
        case .showClaude:        return "Show Claude"
        case .quickOpen:         return "Quick Open"
        case .commandPalette:    return "Command Palette"
        case .nextTab:           return "Next Editor"
        case .previousTab:       return "Previous Editor"
        case .goToLine:          return "Go to Line"
        case .findInFile:        return "Find in File"
        case .findAndReplace:    return "Find and Replace"
        case .toggleComment:     return "Toggle Line Comment"
        case .indentLine:        return "Indent Line"
        case .outdentLine:       return "Outdent Line"
        case .selectNextOccurrence: return "Select Next Occurrence"
        case .zoomIn:            return "Zoom In"
        case .zoomOut:           return "Zoom Out"
        case .resetZoom:         return "Reset Zoom"
        }
    }

    var category: String {
        switch self {
        case .saveFile, .newFile, .closeTab:
            return "File"
        case .toggleSidebar, .toggleTerminal,
             .showExplorer, .showSourceControl, .showSearch, .showDatabase, .showClaude,
             .zoomIn, .zoomOut, .resetZoom:
            return "View"
        case .quickOpen, .commandPalette, .nextTab, .previousTab, .goToLine:
            return "Navigation"
        case .findInFile, .findAndReplace, .toggleComment, .indentLine, .outdentLine,
             .selectNextOccurrence:
            return "Editor"
        }
    }
}

// MARK: - KeyCombo

struct KeyCombo: Equatable, Hashable, Codable, Sendable {
    var key: String      // lowercase char or special name ("backtick", "tab", "f1"…)
    var command: Bool = false
    var shift:   Bool = false
    var option:  Bool = false
    var control: Bool = false

    // MARK: Display

    var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option  { s += "⌥" }
        if shift   { s += "⇧" }
        if command { s += "⌘" }
        switch key {
        case "backtick": s += "`"
        case "tab":      s += "⇥"
        case "enter":    s += "↩"
        case "escape":   s += "⎋"
        case "delete":   s += "⌫"
        case "up":       s += "↑"
        case "down":     s += "↓"
        case "left":     s += "←"
        case "right":    s += "→"
        default:         s += key.uppercased()
        }
        return s
    }

    // MARK: VS Code JSON format ("cmd+shift+e")

    var vsCodeString: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option  { parts.append("alt") }
        if shift   { parts.append("shift") }
        if command { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    static func from(vsCodeString s: String) -> KeyCombo? {
        let parts = s.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last else { return nil }
        let mods = Set(parts.dropLast())
        return KeyCombo(
            key: key,
            command: mods.contains("cmd"),
            shift:   mods.contains("shift"),
            option:  mods.contains("alt"),
            control: mods.contains("ctrl")
        )
    }

    // MARK: NSEvent parsing

    /// Primitive-based factory — safe to call from @Sendable contexts because
    /// no NSEvent crosses the actor boundary; only UInt16/UInt/String do.
    static func from(keyCode: UInt16, modRaw: UInt, chars: String) -> KeyCombo? {
        let flags = NSEvent.ModifierFlags(rawValue: modRaw)
            .intersection([.command, .shift, .option, .control])
        let key = Self.keyName(for: keyCode, chars: chars)
        guard let key else { return nil }
        return KeyCombo(
            key: key,
            command: flags.contains(.command),
            shift:   flags.contains(.shift),
            option:  flags.contains(.option),
            control: flags.contains(.control)
        )
    }

    private static func keyName(for keyCode: UInt16, chars: String) -> String? {
        switch keyCode {
        case 50: return "backtick";  case 48: return "tab"
        case 36: return "enter";     case 53: return "escape"
        case 51: return "delete";    case 117: return "forwarddelete"
        case 126: return "up";       case 125: return "down"
        case 123: return "left";     case 124: return "right"
        case 115: return "home";     case 119: return "end"
        case 116: return "pageup";   case 121: return "pagedown"
        case 122: return "f1";  case 120: return "f2"
        case 99:  return "f3";  case 118: return "f4"
        case 96:  return "f5";  case 97:  return "f6"
        case 98:  return "f7";  case 100: return "f8"
        case 101: return "f9";  case 109: return "f10"
        case 103: return "f11"; case 111: return "f12"
        default:
            let c = chars.lowercased()
            return c.isEmpty ? nil : c
        }
    }

    static func from(_ event: NSEvent) -> KeyCombo? {
        from(keyCode: event.keyCode,
             modRaw: event.modifierFlags.rawValue,
             chars: event.charactersIgnoringModifiers ?? "")
    }
}

// MARK: - KeyBinding

struct KeyBinding: Identifiable, Codable, Sendable {
    var id: String { action.rawValue }
    var action: KeyAction
    var combo: KeyCombo?
    var isCustomized: Bool = false

    // MARK: VS Code macOS defaults

    static let vscodeDefaults: [KeyBinding] = [
        // File
        KeyBinding(action: .saveFile,          combo: KeyCombo(key: "s",   command: true)),
        KeyBinding(action: .newFile,           combo: KeyCombo(key: "n",   command: true)),
        KeyBinding(action: .closeTab,          combo: KeyCombo(key: "w",   command: true)),
        // View
        KeyBinding(action: .toggleSidebar,     combo: KeyCombo(key: "b",   command: true)),
        KeyBinding(action: .toggleTerminal,    combo: KeyCombo(key: "backtick", control: true)),
        KeyBinding(action: .showExplorer,      combo: KeyCombo(key: "e",   command: true, shift: true)),
        KeyBinding(action: .showSourceControl, combo: KeyCombo(key: "g",   command: true, shift: true)),
        KeyBinding(action: .showSearch,        combo: KeyCombo(key: "f",   command: true, shift: true)),
        KeyBinding(action: .showDatabase,      combo: nil),
        KeyBinding(action: .showClaude,        combo: KeyCombo(key: "a",   command: true, shift: true)),
        // Navigation
        KeyBinding(action: .quickOpen,         combo: KeyCombo(key: "p",   command: true)),
        KeyBinding(action: .commandPalette,    combo: KeyCombo(key: "p",   command: true, shift: true)),
        KeyBinding(action: .nextTab,           combo: KeyCombo(key: "tab", control: true)),
        KeyBinding(action: .previousTab,       combo: KeyCombo(key: "tab", shift: true, control: true)),
        KeyBinding(action: .goToLine,          combo: KeyCombo(key: "g",   control: true)),
        // Editor
        KeyBinding(action: .findInFile,        combo: KeyCombo(key: "f",   command: true)),
        KeyBinding(action: .findAndReplace,    combo: KeyCombo(key: "f",   command: true, option: true)),
        KeyBinding(action: .toggleComment,     combo: KeyCombo(key: "/",   command: true)),
        KeyBinding(action: .indentLine,        combo: KeyCombo(key: "]",   command: true)),
        KeyBinding(action: .outdentLine,       combo: KeyCombo(key: "[",   command: true)),
        KeyBinding(action: .selectNextOccurrence, combo: KeyCombo(key: "d", command: true)),
        // Zoom — default binding is Cmd+= (no shift); Cmd++ also triggers it (see dispatchKeyInfo)
        KeyBinding(action: .zoomIn,            combo: KeyCombo(key: "=",   command: true)),
        KeyBinding(action: .zoomOut,           combo: KeyCombo(key: "-",   command: true)),
        KeyBinding(action: .resetZoom,         combo: KeyCombo(key: "0",   command: true)),
    ]

    // Ordered category list for display
    static let categories: [String] = ["File", "View", "Navigation", "Editor"]
}
