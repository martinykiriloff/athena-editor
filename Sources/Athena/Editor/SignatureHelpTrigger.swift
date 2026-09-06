// SignatureHelpTrigger.swift
// Athena — finds the call the caret sits in, and which argument it is on.
// Swift 6, strict concurrency.

import Foundation

/// Pure text scanning that decides whether parameter hints belong on screen.
///
/// The argument index is counted locally rather than asked for, so typing a
/// comma moves the highlight in the same frame instead of after a language
/// server round trip — the difference between hints that feel native and
/// hints that lag behind the caret.
enum SignatureHelpTrigger {

    struct CallContext: Sendable, Equatable {
        /// Offset of the `(` that opened the innermost unclosed call.
        var openParen: Int
        /// Zero-based index of the argument the caret is in.
        var argumentIndex: Int
    }

    /// How far back to scan. A call's opening paren is nearly always a few
    /// characters away; the bound keeps a keystroke's cost constant on a
    /// large file.
    static let lookBack = 4000

    /// The innermost call enclosing `cursor`, or `nil` when the caret is not
    /// inside an argument list.
    ///
    /// Parentheses and commas inside strings, character literals and
    /// comments are ignored, so `format("a, b", |)` is argument 1, not 2.
    static func callContext(text: NSString, cursor: Int) -> CallContext? {
        guard cursor > 0, cursor <= text.length else { return nil }
        let start = max(0, cursor - lookBack)

        var stack: [CallContext] = []
        var quote: unichar? = nil
        var escaped = false
        var inLineComment = false
        var inBlockComment = false
        var i = start

        while i < cursor {
            let c = text.character(at: i)
            let next: unichar? = i + 1 < cursor ? text.character(at: i + 1) : nil

            if inLineComment {
                if c == 0x0A { inLineComment = false }
            } else if inBlockComment {
                if c == 0x2A, next == 0x2F { inBlockComment = false; i += 1 }   // */
            } else if let open = quote {
                if escaped { escaped = false }
                else if c == 0x5C { escaped = true }                            // backslash
                else if c == open { quote = nil }
                else if c == 0x0A, open != 0x60 { quote = nil }                 // unterminated non-backtick string
            } else {
                switch c {
                case 0x2F where next == 0x2F: inLineComment = true;  i += 1     // //
                case 0x2F where next == 0x2A: inBlockComment = true; i += 1     // /*
                case 0x22, 0x27, 0x60:  quote = c                               // " ' `
                case 0x28:  stack.append(CallContext(openParen: i, argumentIndex: 0))
                case 0x29:  if !stack.isEmpty { stack.removeLast() }
                case 0x2C:  if !stack.isEmpty { stack[stack.count - 1].argumentIndex += 1 }
                // A statement boundary means any unclosed paren behind it
                // belongs to code the caret is no longer writing.
                case 0x3B, 0x7B, 0x7D: stack.removeAll()
                default: break
                }
            }
            i += 1
        }
        return stack.last
    }
}
