// InlineCompletionBenchmark.swift
// Athena — fill-in-middle quality and latency of local models, with and
// without cross-file context. Prints numbers; asserts only that it ran.
// Swift 6, strict concurrency.
//
// Opt-in (needs a running Ollama and the models pulled):
//   make bench-fim
//   ATHENA_FIM_MODELS="qwen2.5-coder:7b,qwen3:8b" ATHENA_OLLAMA=http://127.0.0.1:11434 make bench-fim
// Look for "[fim]" lines. Scores: `line` = first line matches exactly
// (whitespace-normalised), `start` = its first 12 characters match, `full`
// = the whole expected middle is produced. Times are to the first streamed
// text and to the finished answer.

import Testing
import Foundation
@testable import Athena

@Suite("InlineCompletionBenchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ATHENA_FIM_BENCH"] != nil))
struct InlineCompletionBenchmark {

    struct Case: Sendable {
        var name: String
        var language: Language
        var prefix: String
        var expected: String
        var suffix: String
        /// Code from "another file" the completion depends on — the
        /// with-context run includes it, the baseline doesn't.
        var related: InlineContextSnippet?
    }

    private var endpoint: String {
        ProcessInfo.processInfo.environment["ATHENA_OLLAMA"] ?? "http://127.0.0.1:11434"
    }

    private var models: [String] {
        (ProcessInfo.processInfo.environment["ATHENA_FIM_MODELS"] ?? "qwen2.5-coder:7b,qwen3:8b")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @Test func fillInMiddle() async {
        for model in models {
            for withContext in [false, true] {
                await run(model: model, withContext: withContext)
            }
        }
    }

    private func run(model: String, withContext: Bool) async {
        // A fresh service per run so the cache never answers.
        let service = InlineCompletionService()
        let config = InlineCompletionService.Config(
            backend: .ollama(endpoint: endpoint, model: model),
            temperature: 0.1, maxTokens: 96, repoName: "bench"
        )
        var line = 0, start = 0, full = 0, errors = 0
        var firstMs: [Double] = [], totalMs: [Double] = []
        let clock = ContinuousClock()

        for c in Self.cases {
            let request = InlineCompletionRequest(
                prefix: c.prefix, suffix: c.suffix, mode: .endOfLine, variant: 0,
                path: "src/\(c.name)", language: c.language, header: "",
                snippets: withContext ? c.related.map { [$0] } ?? [] : []
            )
            let begin = clock.now
            var first: Duration?
            var answer: String?
            for await event in service.stream(request, config: config) {
                switch event {
                case .text: if first == nil { first = clock.now - begin }
                case .finished(let text): answer = text
                case .failed(let message): errors += 1; print("[fim] \(model) \(c.name): \(message)")
                case .rateLimited: break
                }
            }
            totalMs.append(Self.ms(clock.now - begin))
            if let first { firstMs.append(Self.ms(first)) }

            // Shape it exactly as the editor would before showing it.
            let shaped = answer.flatMap { GhostTextPolicy.fit($0, mode: .endOfLine, restOfLine: "", suffix: c.suffix) }
            if ProcessInfo.processInfo.environment["ATHENA_FIM_VERBOSE"] != nil {
                print("[fim]   \(c.name): \(shaped.map { String(reflecting: $0) } ?? "nil")")
            }
            let got = Self.normalise(shaped ?? "")
            let want = Self.normalise(c.expected)
            let gotLine = got.components(separatedBy: "\n").first ?? ""
            let wantLine = want.components(separatedBy: "\n").first ?? ""
            if gotLine == wantLine { line += 1 }
            if gotLine.prefix(12) == wantLine.prefix(12) { start += 1 }
            if got.hasPrefix(want) { full += 1 }
        }

        let n = Self.cases.count
        print(String(format: "[fim] %@ %@: line %d/%d  start %d/%d  full %d/%d  errors %d  first-text median %.0fms  total median %.0fms",
                     model, withContext ? "with context" : "baseline    ",
                     line, n, start, n, full, n, errors, Self.median(firstMs), Self.median(totalMs)))
        #expect(totalMs.count == n)
    }

    // MARK: - Helpers

    private static func normalise(_ s: String) -> String {
        s.components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    // MARK: - Cases (weighted to TypeScript/JavaScript, Athena's audience)

    static let userModel = InlineContextSnippet(path: "src/models/user.ts", text: """
    export interface User {
      id: string
      email: string
      displayName: string
      createdAt: Date
    }
    export async function fetchUser(id: string): Promise<User>
    export function formatUserLabel(user: User): string
    """)

    static let apiClient = InlineContextSnippet(path: "src/lib/api.ts", text: """
    export const api = {
      get<T>(path: string): Promise<T>
      post<T>(path: string, body: unknown): Promise<T>
      delete(path: string): Promise<void>
    }
    """)

    static let cases: [Case] = [
        Case(name: "sum.ts", language: .typescript,
             prefix: "export function sum(values: number[]): number {\n  ",
             expected: "return values.reduce((total, value) => total + value, 0)", suffix: "\n}\n"),
        Case(name: "user-label.ts", language: .typescript,
             prefix: "import { User, formatUserLabel } from './models/user'\n\nexport function renderUser(user: User) {\n  const label = ",
             expected: "formatUserLabel(user)", suffix: "\n  return `<span>${label}</span>`\n}\n", related: userModel),
        Case(name: "fetch.ts", language: .typescript,
             prefix: "import { api } from './lib/api'\nimport { User } from './models/user'\n\nexport async function loadUser(id: string): Promise<User> {\n  return ",
             expected: "api.get<User>(`/users/${id}`)", suffix: "\n}\n", related: apiClient),
        Case(name: "delete.ts", language: .typescript,
             prefix: "import { api } from './lib/api'\n\nexport async function removeUser(id: string): Promise<void> {\n  await ",
             expected: "api.delete(`/users/${id}`)", suffix: "\n}\n", related: apiClient),
        Case(name: "email.ts", language: .typescript,
             prefix: "import { User } from './models/user'\n\nexport function emailDomain(user: User): string {\n  return ",
             expected: "user.email.split('@')[1]", suffix: "\n}\n", related: userModel),
        Case(name: "filter.ts", language: .typescript,
             prefix: "type Todo = { id: number; done: boolean; title: string }\n\nexport function pending(todos: Todo[]): Todo[] {\n  return ",
             expected: "todos.filter(todo => !todo.done)", suffix: "\n}\n"),
        Case(name: "sort.ts", language: .typescript,
             prefix: "import { User } from './models/user'\n\nexport function newestFirst(users: User[]): User[] {\n  return [...users].sort(",
             expected: "(a, b) => b.createdAt.getTime() - a.createdAt.getTime())", suffix: "\n}\n", related: userModel),
        Case(name: "debounce.js", language: .javascript,
             prefix: "export function debounce(fn, ms) {\n  let timer\n  return (...args) => {\n    clearTimeout(timer)\n    ",
             expected: "timer = setTimeout(() => fn(...args), ms)", suffix: "\n  }\n}\n"),
        Case(name: "group.js", language: .javascript,
             prefix: "export function groupBy(items, key) {\n  return items.reduce((groups, item) => {\n    ",
             expected: "(groups[item[key]] ||= []).push(item)", suffix: "\n    return groups\n  }, {})\n}\n"),
        Case(name: "express.js", language: .javascript,
             prefix: "const express = require('express')\nconst app = express()\n\napp.get('/health', (req, res) => {\n  ",
             expected: "res.json({ status: 'ok' })", suffix: "\n})\n"),
        Case(name: "react.tsx", language: .typescript,
             prefix: "import { useState } from 'react'\n\nexport function Counter() {\n  const [count, setCount] = ",
             expected: "useState(0)", suffix: "\n  return <button onClick={() => setCount(count + 1)}>{count}</button>\n}\n"),
        Case(name: "effect.tsx", language: .typescript,
             prefix: "import { useEffect, useState } from 'react'\nimport { User, fetchUser } from './models/user'\n\nexport function useUser(id: string) {\n  const [user, setUser] = useState<User | null>(null)\n  useEffect(() => {\n    ",
             expected: "fetchUser(id).then(setUser)", suffix: "\n  }, [id])\n  return user\n}\n", related: userModel),
        Case(name: "clamp.ts", language: .typescript,
             prefix: "export function clamp(value: number, min: number, max: number): number {\n  return ",
             expected: "Math.min(Math.max(value, min), max)", suffix: "\n}\n"),
        Case(name: "slug.ts", language: .typescript,
             prefix: "export function slugify(title: string): string {\n  return title\n    .toLowerCase()\n    ",
             expected: ".replace(/[^a-z0-9]+/g, '-')", suffix: "\n    .replace(/^-|-$/g, '')\n}\n"),
        Case(name: "zod.ts", language: .typescript,
             prefix: "import { z } from 'zod'\n\nexport const UserSchema = z.object({\n  id: z.string(),\n  email: ",
             expected: "z.string().email(),", suffix: "\n  displayName: z.string(),\n})\n"),
        Case(name: "fetchjson.ts", language: .typescript,
             prefix: "export async function getJSON<T>(url: string): Promise<T> {\n  const response = await fetch(url)\n  if (!response.ok) ",
             expected: "throw new Error(`Request failed: ${response.status}`)", suffix: "\n  return response.json() as Promise<T>\n}\n"),
        Case(name: "Total.swift", language: .swift,
             prefix: "struct Item { let price: Double; let quantity: Int }\n\nfunc total(of items: [Item]) -> Double {\n    ",
             expected: "items.reduce(0) { $0 + $1.price * Double($1.quantity) }", suffix: "\n}\n"),
        Case(name: "Guard.swift", language: .swift,
             prefix: "func port(from string: String) -> Int? {\n    guard let value = Int(string), ",
             expected: "(1...65535).contains(value) else { return nil }", suffix: "\n    return value\n}\n"),
        Case(name: "average.py", language: .python,
             prefix: "def average(values: list[float]) -> float:\n    if not values:\n        return 0.0\n    ",
             expected: "return sum(values) / len(values)", suffix: "\n"),
        Case(name: "styles.css", language: .css,
             prefix: ".center {\n  display: flex;\n  align-items: center;\n  ",
             expected: "justify-content: center;", suffix: "\n}\n"),
    ]
}
