// InlinePromptBuilder.swift
// Athena — turns one InlineCompletionRequest into each backend's prompt, and
// cleans what comes back (fences, echoed prompt, thinking, FIM tokens).
// Swift 6, strict concurrency.

import Foundation

enum InlinePromptBuilder {

    // MARK: - Windows

    /// How much text around the caret each backend sees.
    struct Window: Sendable, Equatable {
        var prefixChars: Int
        var suffixChars: Int
        var contextChars: Int

        /// Local models: small context windows and latency-sensitive.
        static let local = Window(prefixChars: 2000, suffixChars: 500, contextChars: 1500)
        /// Claude: 1M context, so room for more of the file and related code.
        static let cloud = Window(prefixChars: 4000, suffixChars: 1500, contextChars: 6000)
    }

    struct Slice: Sendable, Equatable {
        var prefix: String
        var suffix: String
        /// True when `prefix` doesn't start at the top of the file — the
        /// imports header then has to be supplied separately.
        var prefixTruncated: Bool
    }

    static func slice(_ request: InlineCompletionRequest, window: Window) -> Slice {
        Slice(
            prefix: String(request.prefix.suffix(window.prefixChars)),
            suffix: String(request.suffix.prefix(window.suffixChars)),
            prefixTruncated: request.prefix.count > window.prefixChars
        )
    }

    // MARK: - Claude

    struct ClaudePrompt: Sendable, Equatable {
        var system: String
        var user: String
    }

    static func claude(_ request: InlineCompletionRequest) -> ClaudePrompt {
        let s = slice(request, window: .cloud)
        var system = """
        You are the inline code completion engine of a code editor. You get the file being edited, \
        with the caret marked <CURSOR/>, and sometimes excerpts of related files. Reply with ONLY \
        the exact text to insert at <CURSOR/>: no explanation, no markdown fences, and no repetition \
        of code that is already before or after the caret. Match the file's indentation and style.
        """
        switch request.mode {
        case .endOfLine:
            system += " Complete the current line, or write the next few lines when a block (a function body, a branch, a list of items) is the natural continuation. Stop at a natural boundary, at most 12 lines."
        case .midLine:
            system += " Insert text on the current line only, so that it fits before the existing text that follows <CURSOR/> on that line. Never output a line break."
        }
        if request.variant > 0 {
            system += " Offer a different plausible completion from the most obvious one."
        }

        var user = ""
        if !request.snippets.isEmpty {
            user += "<related_files>\n"
            for snippet in request.snippets {
                user += "<file path=\"\(snippet.path)\">\n\(snippet.text)\n</file>\n"
            }
            user += "</related_files>\n\n"
        }
        user += "<file path=\"\(request.path)\" language=\"\(request.language.displayName)\">\n"
        if s.prefixTruncated, !request.header.isEmpty {
            user += "<file_header>\n\(request.header)\n</file_header>\n…\n"
        }
        user += s.prefix + "<CURSOR/>" + s.suffix + "\n</file>"
        return ClaudePrompt(system: system, user: user)
    }

    // MARK: - Fill-in-middle families

    /// Models whose native fill-in-middle tokens Athena writes itself (in
    /// Ollama's raw mode), which is the only way to give them several files.
    enum FIMFamily: Sendable, Equatable {
        /// Qwen2.5-Coder: `<|fim_prefix|>…<|fim_suffix|>…<|fim_middle|>`,
        /// with `<|repo_name|>` / `<|file_sep|>` for repository context.
        case qwenCoder

        static func detect(model: String) -> FIMFamily? {
            let m = model.lowercased()
            if m.contains("qwen2.5-coder") { return .qwenCoder }
            return nil
        }

        var stopTokens: [String] {
            switch self {
            case .qwenCoder:
                return ["<|endoftext|>", "<|file_sep|>", "<|fim_prefix|>", "<|fim_suffix|>",
                        "<|fim_middle|>", "<|repo_name|>", "<|im_end|>", "<|fim_pad|>"]
            }
        }
    }

    /// A raw prompt in the family's repository fill-in-middle format.
    static func rawFIM(_ request: InlineCompletionRequest, family: FIMFamily, repoName: String) -> String {
        let s = slice(request, window: .local)
        switch family {
        case .qwenCoder:
            var prompt = "<|repo_name|>\(repoName)\n"
            for snippet in request.snippets {
                prompt += "<|file_sep|>\(snippet.path)\n\(snippet.text)\n"
            }
            prompt += "<|file_sep|>\(request.path)\n<|fim_prefix|>"
            if s.prefixTruncated, let header = commentedHeader(request) { prompt += header }
            prompt += s.prefix + "<|fim_suffix|>" + s.suffix + "<|fim_middle|>"
            return prompt
        }
    }

    // MARK: - Generic local prompts

    /// Prompt text for a model reached through a template (Ollama with or
    /// without `suffix`, or OpenAI `/completions`): related code as comments
    /// in the file's own language, then the code before the caret.
    static func commentedPrompt(_ request: InlineCompletionRequest) -> (prompt: String, suffix: String) {
        let s = slice(request, window: .local)
        var prompt = ""
        let token = request.language.lineCommentToken
        if !token.isEmpty {
            for snippet in request.snippets {
                prompt += "\(token) Related code from \(snippet.path):\n"
                for line in snippet.text.components(separatedBy: "\n") {
                    prompt += line.isEmpty ? "\(token)\n" : "\(token) \(line)\n"
                }
                prompt += "\n"
            }
        }
        if s.prefixTruncated, let header = commentedHeader(request) { prompt += header }
        prompt += s.prefix
        return (prompt, s.suffix)
    }

    /// Whether real code (not just closing brackets) follows the caret's
    /// line. A model that can't see the suffix would otherwise rewrite it,
    /// so such models are held to one line there.
    static func hasCodeBelow(_ suffix: String) -> Bool {
        let lines = suffix.components(separatedBy: "\n").dropFirst()
        guard let next = lines.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else {
            return false
        }
        let closers = Set(")]};,")
        return !next.allSatisfy { closers.contains($0) || $0 == " " }
    }

    /// llama.cpp `/infill` body pieces: prefix, suffix, and extra files.
    static func infill(_ request: InlineCompletionRequest) -> (prefix: String, suffix: String, extra: [[String: String]]) {
        let s = slice(request, window: .local)
        var prefix = ""
        if s.prefixTruncated, let header = commentedHeader(request) { prefix += header }
        prefix += s.prefix
        let extra = request.snippets.map { ["filename": $0.path, "text": $0.text] }
        return (prefix, s.suffix, extra)
    }

    private static func commentedHeader(_ request: InlineCompletionRequest) -> String? {
        let token = request.language.lineCommentToken
        guard !request.header.isEmpty, !token.isEmpty else { return nil }
        return request.header
            .components(separatedBy: "\n")
            .map { "\(token) \($0)" }
            .joined(separator: "\n") + "\n"
    }

    // MARK: - Next-edit prediction

    static func nextEdit(_ query: NextEditQuery, path: String, language: Language) -> ClaudePrompt {
        let system = """
        You predict the next edit a developer will make in a file, from the edits they just made. \
        Typical follow-ups: the other uses of something just renamed, call sites after a signature \
        change, the same change on similar neighbouring lines, an import for something just used. \
        Reply with ONLY a JSON object, no markdown: \
        {"original": "<text currently in the excerpt, copied exactly, at most a few lines>", "replacement": "<the new text>"}. \
        The original must occur exactly once in the excerpt and must not be on the line the caret is on. \
        Never repeat an edit that was already made. If no follow-up edit is clearly implied, reply {"none": true}.
        """
        var user = "<file path=\"\(path)\" language=\"\(language.displayName)\" first_line=\"\(query.excerptStartLine)\">\n"
        user += query.excerpt
        user += "\n</file>\n<caret line=\"\(query.cursorLine)\"/>\n<recent_edits>\n"
        for edit in query.edits {
            user += "line \(edit.line):\n- \(edit.before)\n+ \(edit.after)\n"
        }
        user += "</recent_edits>"
        return ClaudePrompt(system: system, user: user)
    }

    /// Reads the model's JSON answer; `nil` for "none", malformed output,
    /// or a no-op.
    static func parseNextEdit(_ text: String) -> NextEditCandidate? {
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["none"] as? Bool) != true,
              let original = json["original"] as? String,
              let replacement = json["replacement"] as? String,
              !original.isEmpty, original != replacement
        else { return nil }
        return NextEditCandidate(original: original, replacement: replacement)
    }

    // MARK: - Cleaning output

    /// Cleans raw model output. While streaming (`final == false`) returns
    /// `nil` until enough has arrived to tell an echoed prompt or a fence
    /// apart from a real answer, so nothing flickers in and out.
    static func clean(_ raw: String, promptTail: String, final: Bool) -> String? {
        var text = raw

        // Thinking models (qwen3, deepseek-r1…) may lead with a think block.
        if let open = text.range(of: "<think>") {
            guard let close = text.range(of: "</think>", range: open.upperBound..<text.endIndex) else {
                return nil   // still thinking
            }
            text.removeSubrange(open.lowerBound..<close.upperBound)
            // The answer proper starts on the line after the think block.
            while text.hasPrefix("\n") || text.hasPrefix("\r") { text.removeFirst() }
        }

        // Stray FIM tokens some servers pass through.
        for token in ["<|endoftext|>", "<|fim_middle|>", "<|file_sep|>", "<|im_end|>", "<EOT>"] {
            if let r = text.range(of: token) { text = String(text[..<r.lowerBound]) }
        }

        if !final {
            let settled = text.contains("\n") || text.count >= 40
            if !settled { return nil }
        }

        // Chat-style answers ("Sure! Here's the function:\n\n```ts …"): the
        // code is the first fenced block, the lead-in is prose.
        if let fence = text.range(of: "```"), fence.lowerBound != text.startIndex {
            let leadIn = text[..<fence.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if leadIn.hasSuffix(":") { text = String(text[fence.lowerBound...]) }
        }

        // Drop a leading ```lang fence (models often put a blank line
        // before it) and anything from a closing fence on.
        let unfenced = text.drop(while: { $0 == "\n" || $0 == "\r" })
        if unfenced.hasPrefix("```") {
            text = String(unfenced)
            guard let firstNewline = text.firstIndex(of: "\n") else { return nil }
            text = String(text[text.index(after: firstNewline)...])
        }
        if let fence = text.range(of: "```") {
            text = String(text[..<fence.lowerBound])
        }
        while text.hasSuffix("\n") || text.hasSuffix("\r") { text.removeLast() }

        // The caret's own line decides what leading whitespace means.
        let caretLine = promptTail.components(separatedBy: "\n").last ?? ""
        let caretLineIsBlank = caretLine.trimmingCharacters(in: .whitespaces).isEmpty
        if caretLineIsBlank {
            // Already on a fresh, indented line: a leading newline is noise,
            // and so is the model re-typing (some of) the indentation.
            while text.hasPrefix("\n") || text.hasPrefix("\r") { text.removeFirst() }
            if !caretLine.isEmpty {
                while text.hasPrefix(" ") || text.hasPrefix("\t") { text.removeFirst() }
            }
        } else if caretLine.hasSuffix(" ") || caretLine.hasSuffix("\t") {
            // "= " + " useState(0)": tokenisers often repeat the space.
            while text.hasPrefix(" ") || text.hasPrefix("\t") { text.removeFirst() }
        } else {
            // At the end of real code a newline starts the next line; keep one.
            while text.hasPrefix("\n\n") { text.removeFirst() }
        }

        // Remove an echoed prompt: the longest tail of the prompt (up to 400
        // chars) the response repeats at its start.
        let maxOverlap = min(promptTail.count, text.count, 400)
        if maxOverlap >= 8 {
            for len in stride(from: maxOverlap, through: 8, by: -1) where text.hasPrefix(String(promptTail.suffix(len))) {
                text = String(text.dropFirst(len))
                break
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}
