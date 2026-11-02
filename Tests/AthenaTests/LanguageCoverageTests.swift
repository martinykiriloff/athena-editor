// LanguageCoverageTests.swift
// Athena — syntax rules, detection and language-server launch resolution for the Wave 2 languages.
// Swift 6, strict concurrency.

import Testing
import Foundation
import AppKit
@testable import Athena

// MARK: - Helpers

private let theme = EditorTheme.athenaDracula

/// The colour a token ends up with: the last span covering its first character.
private func color(of token: String, in text: String, _ language: Language, occurrence: Int = 0) -> NSColor {
    let highlighter = SyntaxHighlighter(language: language, theme: theme)
    let ns = text as NSString
    var searchRange = NSRange(location: 0, length: ns.length)
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0...occurrence {
        found = ns.range(of: token, options: [], range: searchRange)
        guard found.location != NSNotFound else { break }
        searchRange = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
    }
    precondition(found.location != NSNotFound, "token \(token) not in text")
    let spans = highlighter.spans(in: text, range: NSRange(location: 0, length: ns.length))
    return spans.last { NSLocationInRange(found.location, $0.range) }?.color ?? highlighter.baseForeground
}

private func plain(of token: String, in text: String, _ language: Language) -> Bool {
    color(of: token, in: text, language) == theme.foreground
}

// MARK: - Detection

@Suite struct NewLanguageDetectionTests {
    private func detect(_ name: String) -> Language { Language.detect(from: URL(fileURLWithPath: "/p/\(name)")) }

    @Test func extensions() {
        #expect(detect("a.yml") == .yaml)
        #expect(detect("a.yaml") == .yaml)
        #expect(detect("q.sql") == .sql)
        #expect(detect("x.sh") == .shell)
        #expect(detect("x.zsh") == .shell)
        #expect(detect("i.php") == .php)
        #expect(detect("A.java") == .java)
        #expect(detect("A.kt") == .kotlin)
        #expect(detect("a.c") == .c)
        #expect(detect("a.h") == .c)
        #expect(detect("a.cpp") == .cpp)
        #expect(detect("a.hpp") == .cpp)
        #expect(detect("a.rb") == .ruby)
        #expect(detect("A.vue") == .vue)
        #expect(detect("A.svelte") == .svelte)
        #expect(detect("Cargo.toml") == .toml)
        #expect(detect("s.graphql") == .graphql)
        #expect(detect("A.TSX") == .typescript)
        #expect(detect("A.jsx") == .javascript)
        #expect(detect("README") == .plaintext)
    }

    @Test func wellKnownFileNames() {
        #expect(detect("Dockerfile") == .dockerfile)
        #expect(detect("Dockerfile.prod") == .dockerfile)
        #expect(detect("app.dockerfile") == .dockerfile)
        #expect(detect(".env") == .env)
        #expect(detect(".env.local") == .env)
        #expect(detect("prod.env") == .env)
        #expect(detect("Makefile") == .shell)
        #expect(detect("rules.mk") == .shell)
        #expect(detect(".zshrc") == .shell)
        #expect(detect("Gemfile") == .ruby)
    }

    @Test func lspIdsAndCommentTokens() {
        let tsx = URL(fileURLWithPath: "/a/B.tsx")
        #expect(Language.typescript.lspLanguageId(for: tsx) == "typescriptreact")
        #expect(Language.javascript.lspLanguageId(for: URL(fileURLWithPath: "/a/B.jsx")) == "javascriptreact")
        #expect(Language.shell.lspLanguageId(for: tsx) == "shellscript")
        #expect(Language.sql.lineCommentToken == "--")
        #expect(Language.yaml.lineCommentToken == "#")
        #expect(Language.php.lineCommentToken == "//")
        #expect(Language.vue.lineCommentToken == "")
        for language in Language.allCases { #expect(!language.displayName.isEmpty) }
    }
}

// MARK: - Highlighting

@Suite struct NewLanguageHighlightTests {

    @Test func jsxTagsGetKeywordColourButGenericsDoNot() {
        let src = "const a = <Button onClick={f}>hi</Button>;\nconst b: Array<string> = foo<T>(x);"
        #expect(color(of: "Button", in: src, .typescript) == theme.keyword)
        #expect(color(of: "Button", in: src, .typescript, occurrence: 1) == theme.keyword)
        #expect(color(of: "const", in: src, .typescript) == theme.keyword)
        // Generic argument lists are not mistaken for tags.
        #expect(color(of: "<string>", in: src, .typescript) != theme.keyword)
        #expect(color(of: "<T>", in: src, .typescript) != theme.keyword)
        #expect(color(of: "div", in: "return <div className=\"x\" />", .javascript) == theme.keyword)
    }

    @Test func yaml() {
        let src = "name: web # note\nitems:\n  - port: 8080\n    on: true\nmsg: \"hi\"\n"
        #expect(color(of: "name", in: src, .yaml) == theme.type)
        #expect(color(of: "port", in: src, .yaml) == theme.type)
        #expect(color(of: "8080", in: src, .yaml) == theme.number)
        #expect(color(of: "true", in: src, .yaml) == theme.keyword)
        #expect(color(of: "\"hi\"", in: src, .yaml) == theme.string)
        #expect(color(of: "# note", in: src, .yaml) == theme.comment)
    }

    @Test func sql() {
        let src = "SELECT id, count(*) FROM users WHERE name = 'a' -- c\n/* b */"
        #expect(color(of: "SELECT", in: src, .sql) == theme.keyword)
        #expect(color(of: "FROM", in: src, .sql) == theme.keyword)
        #expect(color(of: "count", in: src, .sql) == theme.function)
        #expect(color(of: "'a'", in: src, .sql) == theme.string)
        #expect(color(of: "-- c", in: src, .sql) == theme.comment)
        #expect(color(of: "/* b */", in: src, .sql) == theme.comment)
        #expect(plain(of: "users", in: src, .sql))
    }

    @Test func shell() {
        let src = "#!/bin/sh\nif [ -f \"$HOME/x\" ]; then\n  echo $USER # hi\nfi\ncat <<EOF\nif $X\nEOF\n"
        #expect(color(of: "#!/bin/sh", in: src, .shell) == theme.comment)
        #expect(color(of: "if", in: src, .shell) == theme.keyword)
        #expect(color(of: "then", in: src, .shell) == theme.keyword)
        #expect(color(of: "echo", in: src, .shell) == theme.function)
        #expect(color(of: "$USER", in: src, .shell) == theme.type)
        #expect(color(of: "# hi", in: src, .shell) == theme.comment)
        // Heredoc body is a string, not keywords.
        #expect(color(of: "if", in: src, .shell, occurrence: 1) == theme.string)
    }

    @Test func php() {
        let src = "<?php\nfunction add($a) { return $a + 1; } // c\n$s = 'x';\n"
        #expect(color(of: "<?php", in: src, .php) == theme.keyword)
        #expect(color(of: "function", in: src, .php) == theme.keyword)
        #expect(color(of: "$a", in: src, .php) == theme.type)
        #expect(color(of: "add", in: src, .php) == theme.function)
        #expect(color(of: "'x'", in: src, .php) == theme.string)
        #expect(color(of: "// c", in: src, .php) == theme.comment)
    }

    @Test func java() {
        let src = "@Override\npublic class A { int x = 42; String s = \"q\"; /* c */ }"
        #expect(color(of: "@Override", in: src, .java) == theme.type)
        #expect(color(of: "public", in: src, .java) == theme.keyword)
        #expect(color(of: "42", in: src, .java) == theme.number)
        #expect(color(of: "\"q\"", in: src, .java) == theme.string)
        #expect(color(of: "/* c */", in: src, .java) == theme.comment)
    }

    @Test func kotlin() {
        let src = "fun main() { val s = \"\"\"a\nb\"\"\" } // z"
        #expect(color(of: "fun", in: src, .kotlin) == theme.keyword)
        #expect(color(of: "val", in: src, .kotlin) == theme.keyword)
        #expect(color(of: "b\"\"\"", in: src, .kotlin) == theme.string)
        #expect(color(of: "// z", in: src, .kotlin) == theme.comment)
    }

    @Test func cAndCpp() {
        let c = "#include <stdio.h>\nint main(void) { return 0; } // e"
        #expect(color(of: "#include", in: c, .c) == theme.keyword)
        #expect(color(of: "int", in: c, .c) == theme.keyword)
        #expect(color(of: "main", in: c, .c) == theme.function)
        #expect(color(of: "// e", in: c, .c) == theme.comment)
        let cpp = "namespace n { auto s = R\"x(a\nb)x\"; }"
        #expect(color(of: "namespace", in: cpp, .cpp) == theme.keyword)
        #expect(color(of: "b)x\"", in: cpp, .cpp) == theme.string)
    }

    @Test func ruby() {
        let src = "def hi(x)\n  puts :sym, @iv # c\nend\n=begin\nblock\n=end\n"
        #expect(color(of: "def", in: src, .ruby) == theme.keyword)
        #expect(color(of: "@iv", in: src, .ruby) == theme.type)
        #expect(color(of: ":sym", in: src, .ruby) == theme.number)
        #expect(color(of: "# c", in: src, .ruby) == theme.comment)
        #expect(color(of: "block", in: src, .ruby) == theme.comment)
    }

    @Test func vueAndSvelte() {
        let vue = "<template>\n  <div class=\"a\" :id=\"x\">{{ msg }}</div>\n</template>\n<script>\nexport default {}\n</script>"
        #expect(color(of: "div", in: vue, .vue) == theme.function)
        #expect(color(of: "\"a\"", in: vue, .vue) == theme.string)
        #expect(color(of: ":id", in: vue, .vue) == theme.keyword)
        #expect(color(of: "{{ msg }}", in: vue, .vue) == theme.number)
        #expect(color(of: "export", in: vue, .vue) == theme.keyword)
        let svelte = "{#if ok}\n<p on:click={go}>x</p>\n{/if}"
        #expect(color(of: "{#if ok}", in: svelte, .svelte) == theme.keyword)
        #expect(color(of: "on:click", in: svelte, .svelte) == theme.keyword)
    }

    @Test func toml() {
        let src = "# c\n[server]\nport = 8080\nname = \"x\"\nok = true\n"
        #expect(color(of: "# c", in: src, .toml) == theme.comment)
        #expect(color(of: "[server]", in: src, .toml) == theme.keyword)
        #expect(color(of: "port", in: src, .toml) == theme.type)
        #expect(color(of: "8080", in: src, .toml) == theme.number)
        #expect(color(of: "\"x\"", in: src, .toml) == theme.string)
        #expect(color(of: "true", in: src, .toml) == theme.keyword)
    }

    @Test func graphql() {
        let src = "query Q($id: ID!) { user(id: $id) { name } } # c"
        #expect(color(of: "query", in: src, .graphql) == theme.keyword)
        #expect(color(of: "ID", in: src, .graphql) == theme.type)
        #expect(color(of: "$id", in: src, .graphql) == theme.type)
        #expect(color(of: "# c", in: src, .graphql) == theme.comment)
    }

    @Test func env() {
        let src = "# top\nexport KEY=value\nURL=\"http://x\" \nREF=${KEY}\n"
        #expect(color(of: "# top", in: src, .env) == theme.comment)
        #expect(color(of: "KEY", in: src, .env) == theme.type)
        #expect(color(of: "export", in: src, .env) == theme.keyword)
        #expect(color(of: "value", in: src, .env) == theme.string)
        #expect(color(of: "${KEY}", in: src, .env) == theme.function)
    }

    @Test func dockerfile() {
        let src = "# base\nFROM node:20 AS build\nRUN npm ci && echo $HOME\nCOPY --from=build /a /b\n"
        #expect(color(of: "# base", in: src, .dockerfile) == theme.comment)
        #expect(color(of: "FROM", in: src, .dockerfile) == theme.keyword)
        #expect(color(of: "AS", in: src, .dockerfile) == theme.keyword)
        #expect(color(of: "RUN", in: src, .dockerfile) == theme.keyword)
        #expect(color(of: "$HOME", in: src, .dockerfile) == theme.function)
        #expect(color(of: "--from", in: src, .dockerfile) == theme.type)
    }

    @Test func everyLanguageBuildsRulesWithoutCrashing() {
        for language in Language.allCases {
            let h = SyntaxHighlighter(language: language, theme: theme)
            _ = h.highlight("x = 1 // y\n")
        }
    }
}

// MARK: - HighlightPlanner fallbacks

@Suite struct NewLanguagePlannerTests {
    private func plan(_ text: String, at location: Int, _ language: Language) -> HighlightPlan {
        HighlightPlanner.plan(
            text: text as NSString,
            edit: HighlightEdit(range: NSRange(location: location, length: 1), deletedText: ""),
            language: language,
            isNewlineColored: { _ in false })
    }

    @Test func multiLineDelimitersForceFullPass() {
        #expect(plan("a\ncat <<EOF\nb\n", at: 0, .shell) == .full)
        #expect(plan("a\n=begin\nb\n", at: 0, .ruby) == .full)
        #expect(plan("a\nx = \"\"\"\nb\n", at: 0, .kotlin) == .full)
        #expect(plan("a\n/* x\nb\n", at: 0, .cpp) == .full)
        #expect(plan("a\n<!-- x\nb\n", at: 0, .vue) == .full)
        #expect(plan("a\nx = '''\nb\n", at: 0, .toml) == .full)
        #expect(plan("a\n<<<EOT\nb\n", at: 0, .php) == .full)
        #expect(plan("a\n/* x\nb\n", at: 0, .sql) == .full)
    }

    @Test func plainEditsStayWindowed() {
        for language in [Language.yaml, .sql, .shell, .php, .java, .kotlin, .c, .cpp, .ruby,
                         .vue, .svelte, .toml, .graphql, .env, .dockerfile] {
            if case .window = plan("one\ntwo\nthree\nfour\nfive\n", at: 9, language) { continue }
            Issue.record("\(language) plain edit was not windowed")
        }
    }
}

// MARK: - Language server catalog

@Suite struct LanguageServerCatalogTests {
    private func lookups(path: [String: String] = [:], executables: Set<String> = []) -> LanguageServerLookups {
        LanguageServerLookups(executableNamed: { path[$0] }, isExecutable: { executables.contains($0) })
    }

    @Test func foundOnPathUsesDefaultArguments() async {
        let l = lookups(path: ["vscode-css-language-server": "/n/bin/vscode-css-language-server"])
        let r = await LanguageServerCatalog.resolve(language: .css, override: nil, lookups: l)
        #expect(r == LanguageServerLaunch(executable: "/n/bin/vscode-css-language-server", arguments: ["--stdio"]))
    }

    @Test func fixedPathsAreTheFallback() async {
        let fixed = "/opt/homebrew/bin/yaml-language-server"
        let r = await LanguageServerCatalog.resolve(language: .yaml, override: nil, lookups: lookups(executables: [fixed]))
        #expect(r?.executable == fixed)
        #expect(r?.arguments == ["--stdio"])
    }

    @Test func missingServerResolvesToNil() async {
        for language in [Language.html, .json, .vue, .svelte, .python, .rust, .go, .typescript] {
            let r = await LanguageServerCatalog.resolve(language: language, override: nil, lookups: lookups())
            #expect(r == nil)
        }
        #expect(await LanguageServerCatalog.resolve(language: .sql, override: nil, lookups: lookups()) == nil)
    }

    @Test func pythonAndRustTakeNoStdioFlag() async {
        let l = lookups(path: ["pylsp": "/b/pylsp", "rust-analyzer": "/b/ra"])
        #expect(await LanguageServerCatalog.resolve(language: .python, override: nil, lookups: l)?.arguments == [])
        #expect(await LanguageServerCatalog.resolve(language: .rust, override: nil, lookups: l)?.arguments == [])
    }

    @Test func swiftPrefersSourcekitThenXcrun() async {
        let both = lookups(executables: ["/usr/bin/sourcekit-lsp", "/usr/bin/xcrun"])
        #expect(await LanguageServerCatalog.resolve(language: .swift, override: nil, lookups: both)
                == LanguageServerLaunch(executable: "/usr/bin/sourcekit-lsp", arguments: []))
        let xcrun = lookups(executables: ["/usr/bin/xcrun"])
        #expect(await LanguageServerCatalog.resolve(language: .swift, override: nil, lookups: xcrun)
                == LanguageServerLaunch(executable: "/usr/bin/xcrun", arguments: ["sourcekit-lsp"]))
    }

    @Test func overridePathAndArguments() async {
        let l = lookups(path: ["mylsp": "/x/mylsp"], executables: ["/custom/yaml-ls"])
        let abs = await LanguageServerCatalog.resolve(
            language: .yaml, override: LanguageServerOverride(path: "/custom/yaml-ls", arguments: "--stdio --foo 'a b'"),
            lookups: l)
        #expect(abs == LanguageServerLaunch(executable: "/custom/yaml-ls", arguments: ["--stdio", "--foo", "a b"]))
        let bare = await LanguageServerCatalog.resolve(
            language: .yaml, override: LanguageServerOverride(path: "mylsp"), lookups: l)
        #expect(bare == LanguageServerLaunch(executable: "/x/mylsp", arguments: ["--stdio"]))
    }

    @Test func badOverrideDoesNotFallBackSilently() async {
        let l = lookups(path: ["yaml-language-server": "/n/yaml-language-server"])
        let r = await LanguageServerCatalog.resolve(
            language: .yaml, override: LanguageServerOverride(path: "/nope/yaml"), lookups: l)
        #expect(r == nil)
    }

    @Test func argumentsOnlyOverrideKeepsDefaultExecutable() async {
        let l = lookups(path: ["gopls": "/g/gopls"])
        let r = await LanguageServerCatalog.resolve(
            language: .go, override: LanguageServerOverride(arguments: "serve"), lookups: l)
        #expect(r == LanguageServerLaunch(executable: "/g/gopls", arguments: ["serve"]))
    }

    @Test func emptyOverrideIsIgnored() async {
        let l = lookups(path: ["gopls": "/g/gopls"])
        let r = await LanguageServerCatalog.resolve(language: .go, override: LanguageServerOverride(), lookups: l)
        #expect(r?.executable == "/g/gopls")
    }

    @Test func splitArgumentsHandlesQuotes() {
        #expect(LanguageServerCatalog.splitArguments("  a  \"b c\" d='e f' ") == ["a", "b c", "d=e f"])
        #expect(LanguageServerCatalog.splitArguments("").isEmpty)
    }

    @Test func overridesRoundTripThroughStorageKeys() {
        let stored = AppState.encodeOverrides([.yaml: LanguageServerOverride(path: "/a"), .go: LanguageServerOverride()])
        #expect(Set(stored.keys) == ["yaml"])
        #expect(AppState.decodeOverrides(stored)[.yaml]?.path == "/a")
    }
}

// MARK: - Tool notices

@Suite struct LanguageServerNoticeTests {
    @Test func installHints() {
        #expect(ToolCheckService.languageServerNotice(for: .yaml)?.installCommand == "npm install -g yaml-language-server")
        #expect(ToolCheckService.languageServerNotice(for: .css)?.installCommand == "npm install -g vscode-langservers-extracted")
        #expect(ToolCheckService.languageServerNotice(for: .vue)?.installCommand.contains("@vue/language-server") == true)
        #expect(ToolCheckService.languageServerNotice(for: .svelte)?.installCommand.contains("svelte-language-server") == true)
    }

    @Test func sharedInstallsShareOneNoticeId() {
        let ids = [Language.css, .html, .json].compactMap { ToolCheckService.languageServerNotice(for: $0)?.id }
        #expect(Set(ids).count == 1)
        #expect(ToolCheckService.languageServerNotice(for: .javascript)?.id == ToolCheckService.languageServerNotice(for: .typescript)?.id)
        #expect(ToolCheckService.languageServerNotice(for: .typescript)?.id == "lsp.typescript")
    }

    @Test func noNoticeWhereThereIsNoServer() {
        #expect(ToolCheckService.languageServerNotice(for: .swift) == nil)
        #expect(ToolCheckService.languageServerNotice(for: .sql) == nil)
        #expect(ToolCheckService.languageServerNotice(for: .markdown) == nil)
    }
}
