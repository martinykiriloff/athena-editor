// EditorConfigTests.swift
// Athena — tests for .editorconfig parsing, glob matching and save transforms.
// Swift 6, strict concurrency.

import Testing
import Foundation
@testable import Athena

@Suite("EditorConfig parsing")
struct EditorConfigParsingTests {
    @Test func parsesRootSectionsAndComments() {
        let f = EditorConfigFile.parse("""
        # top
        root = true

        [*]
        indent_style = space ; not a comment-strip, value kept
        INDENT_SIZE = 2

        [*.md]
        trim_trailing_whitespace = false
        """)
        #expect(f.isRoot)
        #expect(f.sections.count == 2)
        #expect(f.sections[0].properties["indent_size"] == "2")
        #expect(f.sections[1].properties["trim_trailing_whitespace"] == "false")
    }

    @Test func settingsMapping() {
        let s = EditorConfigFile.settings(from: [
            "indent_style": "Tab", "tab_width": "8", "end_of_line": "crlf",
            "trim_trailing_whitespace": "true", "insert_final_newline": "false", "charset": "UTF-8",
        ])
        #expect(s.indentStyleSpaces == false)
        #expect(s.effectiveIndentWidth == 8)
        #expect(s.endOfLine == .crlf)
        #expect(s.trimTrailingWhitespace == true)
        #expect(s.insertFinalNewline == false)
        #expect(s.charset == "utf-8")
    }

    @Test func unsetAndInvalidAreIgnored() {
        let s = EditorConfigFile.settings(from: ["indent_size": "unset", "end_of_line": "bogus", "tab_width": "-3"])
        #expect(s == .empty)
    }

    @Test func indentSizeTabImpliesTabs() {
        let s = EditorConfigFile.settings(from: ["indent_size": "tab"])
        #expect(s.indentStyleSpaces == false)
        #expect(s.indentSize == nil)
    }

    @Test func laterSectionsOverrideEarlier() {
        let f = EditorConfigFile.parse("[*]\nindent_size = 2\n[*.js]\nindent_size = 4\n")
        #expect(f.properties(forRelativePath: "a/b.js")["indent_size"] == "4")
        #expect(f.properties(forRelativePath: "b.ts")["indent_size"] == "2")
    }
}

@Suite("EditorConfig glob")
struct EditorConfigGlobTests {
    @Test func starMatchesBasenameAtAnyDepth() {
        #expect(EditorConfigGlob.matches(glob: "*.js", relativePath: "a/b/c.js"))
        #expect(EditorConfigGlob.matches(glob: "*", relativePath: "x/y"))
        #expect(!EditorConfigGlob.matches(glob: "*.js", relativePath: "c.jsx"))
    }

    @Test func slashAnchorsAndStarDoesNotCrossSlash() {
        #expect(EditorConfigGlob.matches(glob: "src/*.js", relativePath: "src/a.js"))
        #expect(!EditorConfigGlob.matches(glob: "src/*.js", relativePath: "src/x/a.js"))
        #expect(!EditorConfigGlob.matches(glob: "src/*.js", relativePath: "lib/src/a.js"))
        #expect(EditorConfigGlob.matches(glob: "/src/*.js", relativePath: "src/a.js"))
    }

    @Test func doubleStarCrossesDirectories() {
        #expect(EditorConfigGlob.matches(glob: "src/**.js", relativePath: "src/x/y/a.js"))
        #expect(EditorConfigGlob.matches(glob: "**/lib/*.rb", relativePath: "a/b/lib/x.rb"))
    }

    @Test func braceAlternatives() {
        #expect(EditorConfigGlob.matches(glob: "*.{js,ts}", relativePath: "a.ts"))
        #expect(EditorConfigGlob.matches(glob: "*.{js,ts}", relativePath: "a.js"))
        #expect(!EditorConfigGlob.matches(glob: "*.{js,ts}", relativePath: "a.css"))
        #expect(EditorConfigGlob.matches(glob: "{package.json,.travis.yml}", relativePath: "package.json"))
    }

    @Test func numericRangeAndQuestionMark() {
        #expect(EditorConfigGlob.matches(glob: "file{1..3}.txt", relativePath: "file2.txt"))
        #expect(!EditorConfigGlob.matches(glob: "file{1..3}.txt", relativePath: "file4.txt"))
        #expect(EditorConfigGlob.matches(glob: "a?.c", relativePath: "ab.c"))
        #expect(!EditorConfigGlob.matches(glob: "a?.c", relativePath: "a/.c"))
    }

    @Test func charClasses() {
        #expect(EditorConfigGlob.matches(glob: "[abc].txt", relativePath: "b.txt"))
        #expect(!EditorConfigGlob.matches(glob: "[!abc].txt", relativePath: "b.txt"))
        #expect(EditorConfigGlob.matches(glob: "[!abc].txt", relativePath: "d.txt"))
    }

    @Test func literalDotIsEscaped() {
        #expect(!EditorConfigGlob.matches(glob: "a.c", relativePath: "abc"))
        #expect(EditorConfigGlob.matches(glob: "Makefile", relativePath: "sub/Makefile"))
    }
}

@Suite("EditorConfig resolution")
struct EditorConfigResolutionTests {
    @Test func nearestWinsAndRootStops() {
        let files: [String: String] = [
            "/p": "root = true\n[*]\nindent_size = 2\ninsert_final_newline = true\n",
            "/p/sub": "[*.js]\nindent_size = 8\n",
            "/above": "[*]\nend_of_line = crlf\n",
        ]
        let s = EditorConfigFile.resolve(filePath: "/p/sub/a.js") { files[$0] }
        #expect(s.indentSize == 8)
        #expect(s.insertFinalNewline == true)
        #expect(s.endOfLine == nil) // /above is beyond root = true
    }

    @Test func missingConfigsGiveEmpty() {
        #expect(EditorConfigFile.resolve(filePath: "/a/b/c.txt") { _ in nil } == .empty)
    }

    @Test func parentAppliesWithoutRoot() {
        let files = ["/": "[*]\ncharset = utf-8\n"]
        #expect(EditorConfigFile.resolve(filePath: "/a/b.txt") { files[$0] }.charset == "utf-8")
    }

    @Test func relativePathIsRelativeToConfigDir() {
        let files = ["/p": "[src/*.js]\nindent_size = 3\n"]
        #expect(EditorConfigFile.resolve(filePath: "/p/src/a.js") { files[$0] }.indentSize == 3)
        #expect(EditorConfigFile.resolve(filePath: "/p/other/a.js") { files[$0] }.indentSize == nil)
    }
}

@Suite("Save transforms")
struct SaveTransformsTests {
    @Test func trimsLfCrlfAndEof() {
        #expect(SaveTransforms.trimTrailingWhitespace("a  \nb\t\n  \nc ") == "a\nb\n\nc")
        #expect(SaveTransforms.trimTrailingWhitespace("a  \r\nb \r\n") == "a\r\nb\r\n")
        #expect(SaveTransforms.trimTrailingWhitespace("  keep leading\n") == "  keep leading\n")
        #expect(SaveTransforms.trimTrailingWhitespace("a b") == "a b")
    }

    @Test func finalNewline() {
        #expect(SaveTransforms.ensureFinalNewline("a") == "a\n")
        #expect(SaveTransforms.ensureFinalNewline("a\n") == "a\n")
        #expect(SaveTransforms.ensureFinalNewline("a\r\n") == "a\r\n")
        #expect(SaveTransforms.ensureFinalNewline("") == "")
        #expect(SaveTransforms.ensureFinalNewline("a", ending: "\r\n") == "a\r\n")
        #expect(SaveTransforms.ensureFinalNewline("a\n\n") == "a\n\n")
    }

    @Test func normalizeEndings() {
        #expect(SaveTransforms.normalizeLineEndings("a\r\nb\nc\rd", to: .lf) == "a\nb\nc\nd")
        #expect(SaveTransforms.normalizeLineEndings("a\nb", to: .crlf) == "a\r\nb")
    }

    @Test func applyUsesEditorConfigOverSettings() {
        var cfg = EditorConfigSettings()
        cfg.trimTrailingWhitespace = false
        cfg.insertFinalNewline = true
        #expect(SaveTransforms.apply(to: "a  ", trimSetting: true, finalNewlineSetting: false, config: cfg) == "a  \n")
        #expect(SaveTransforms.apply(to: "a  ", trimSetting: true, finalNewlineSetting: false, config: .empty) == "a")
        #expect(SaveTransforms.apply(to: "a  ", trimSetting: false, finalNewlineSetting: false, config: .empty) == "a  ")
    }

    @Test func finalNewlineMatchesDetectedEnding() {
        #expect(SaveTransforms.apply(to: "a\r\nb", trimSetting: false, finalNewlineSetting: true, config: .empty) == "a\r\nb\r\n")
    }

    @Test func endOfLineConfigConverts() {
        var cfg = EditorConfigSettings()
        cfg.endOfLine = .crlf
        cfg.insertFinalNewline = true
        #expect(SaveTransforms.apply(to: "a\nb", trimSetting: false, finalNewlineSetting: false, config: cfg) == "a\r\nb\r\n")
    }
}
