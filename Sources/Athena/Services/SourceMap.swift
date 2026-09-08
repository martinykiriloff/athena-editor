// SourceMap.swift
// Athena — Source Map v3 decoding, so a breakpoint set in TypeScript lands
//          in the JavaScript a runtime actually executes.
// Swift 6, strict concurrency.

import Foundation

/// One decoded mapping segment. All positions are zero-based, as in the
/// file format; callers convert at the edges.
struct SourceMapSegment: Sendable, Equatable {
    var generatedLine: Int
    var generatedColumn: Int
    var sourceIndex: Int
    var originalLine: Int
    var originalColumn: Int
}

/// A parsed Source Map v3.
///
/// Bundlers ship the code a runtime runs, not the code the user wrote, so a
/// breakpoint on `use-client.ts:12` means nothing to V8 until it is
/// translated into a position inside the generated chunk. This does that
/// translation, and the reverse for reporting where execution stopped.
struct SourceMap: Sendable {
    var sources: [String]
    var sourceRoot: String?
    var segments: [SourceMapSegment]

    // MARK: - Parsing

    static func parse(_ data: Data) -> SourceMap? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(json: json)
    }

    static func parse(json: [String: Any]) -> SourceMap? {
        // An index map ("sections") is a different shape; not supported.
        guard let mappings = json["mappings"] as? String,
              let sources = json["sources"] as? [String] else { return nil }
        return SourceMap(
            sources: sources,
            sourceRoot: json["sourceRoot"] as? String,
            segments: decode(mappings: mappings)
        )
    }

    /// Decodes the `mappings` field: lines separated by `;`, segments by
    /// `,`, each segment a run of Base64 VLQ numbers that are *relative* to
    /// the previous segment's values.
    static func decode(mappings: String) -> [SourceMapSegment] {
        var result: [SourceMapSegment] = []
        var generatedLine = 0
        var sourceIndex = 0
        var originalLine = 0
        var originalColumn = 0

        for line in mappings.split(separator: ";", omittingEmptySubsequences: false) {
            var generatedColumn = 0
            for segment in line.split(separator: ",", omittingEmptySubsequences: true) {
                var cursor = segment.startIndex
                var values: [Int] = []
                while cursor < segment.endIndex, let value = decodeVLQ(segment, &cursor) {
                    values.append(value)
                }
                guard !values.isEmpty else { continue }
                generatedColumn += values[0]
                guard values.count >= 4 else { continue }   // a generated-only segment
                sourceIndex    += values[1]
                originalLine   += values[2]
                originalColumn += values[3]
                result.append(SourceMapSegment(
                    generatedLine: generatedLine,
                    generatedColumn: generatedColumn,
                    sourceIndex: sourceIndex,
                    originalLine: originalLine,
                    originalColumn: originalColumn
                ))
            }
            generatedLine += 1
        }
        return result
    }

    private static let base64 = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

    private static func decodeVLQ(_ segment: Substring, _ cursor: inout Substring.Index) -> Int? {
        var result = 0
        var shift = 0
        var keepGoing = true
        while keepGoing {
            guard cursor < segment.endIndex, let digit = base64.firstIndex(of: segment[cursor]) else { return nil }
            cursor = segment.index(after: cursor)
            keepGoing = digit & 32 != 0
            result += (digit & 31) << shift
            shift += 5
        }
        // Bit 0 is the sign.
        let negative = result & 1 == 1
        result >>= 1
        return negative ? -result : result
    }

    // MARK: - Lookups

    /// The generated line (1-based) that a source's line (1-based) compiles
    /// to, picking the earliest mapping at or after that line so a
    /// breakpoint on a blank or comment line still lands on real code.
    func generatedLine(forSourceMatching path: String, originalLine: Int) -> Int? {
        guard let index = sourceIndex(matching: path) else { return nil }
        let target = originalLine - 1
        let candidates = segments.filter { $0.sourceIndex == index && $0.originalLine >= target }
        guard let best = candidates.min(by: {
            $0.originalLine != $1.originalLine
                ? $0.originalLine < $1.originalLine
                : $0.generatedLine < $1.generatedLine
        }) else { return nil }
        return best.generatedLine + 1
    }

    /// Where a generated position came from, for reporting the stop
    /// location in the file the user is actually looking at.
    func originalPosition(generatedLine: Int, generatedColumn: Int = 0) -> (source: String, line: Int)? {
        let line = generatedLine - 1
        let onLine = segments.filter { $0.generatedLine == line }
        guard !onLine.isEmpty else { return nil }
        // The last mapping at or before the column owns that position.
        let atOrBefore = onLine.filter { $0.generatedColumn <= generatedColumn }
        let best = atOrBefore.max(by: { $0.generatedColumn < $1.generatedColumn })
            ?? onLine.min(by: { $0.generatedColumn < $1.generatedColumn })!
        guard sources.indices.contains(best.sourceIndex) else { return nil }
        return (sources[best.sourceIndex], best.originalLine + 1)
    }

    /// Whether this map covers `path`, and which source entry it is.
    ///
    /// Bundler source names are rarely plain paths — `webpack://_N_E/./src/x.ts`,
    /// `../../src/x.ts`, `turbopack://[project]/src/x.ts` — so matching is by
    /// normalised path suffix rather than equality.
    func sourceIndex(matching path: String) -> Int? {
        let wanted = Self.normalise(path)
        var best: (index: Int, length: Int)?
        for (index, source) in sources.enumerated() {
            let candidate = Self.normalise(source)
            guard candidate == wanted
                    || candidate.hasSuffix("/" + wanted)
                    || wanted.hasSuffix("/" + candidate) else { continue }
            let overlap = min(candidate.count, wanted.count)
            if best == nil || overlap > best!.length { best = (index, overlap) }
        }
        return best?.index
    }

    /// Strips scheme, bundler prefix, query and relative segments so two
    /// spellings of the same file compare equal.
    static func normalise(_ path: String) -> String {
        var value = path
        if let queryStart = value.firstIndex(of: "?") { value = String(value[..<queryStart]) }
        // "webpack://_N_E/./src/x.ts" → "src/x.ts", "turbopack://[project]/src/x.ts" → "src/x.ts"
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
            if let slash = value.firstIndex(of: "/") { value = String(value[value.index(after: slash)...]) }
        }
        if value.hasPrefix("file://") { value = String(value.dropFirst("file://".count)) }
        while value.hasPrefix("./") || value.hasPrefix("../") {
            value = value.hasPrefix("./") ? String(value.dropFirst(2)) : String(value.dropFirst(3))
        }
        if value.hasPrefix("/") { value = String(value.dropFirst()) }
        return value
    }
}
