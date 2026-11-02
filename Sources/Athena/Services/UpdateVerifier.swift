// UpdateVerifier.swift
// Athena — SHA-256 checksum and code-signature checks for downloaded updates.
// Swift 6, strict concurrency.

import Foundation
import CryptoKit

enum UpdateVerificationError: LocalizedError, Equatable {
    case checksumMissing
    case checksumMalformed
    case checksumMismatch(expected: String, actual: String)
    case signatureInvalid(String)

    var errorDescription: String? {
        switch self {
        case .checksumMissing:
            return "The release has no SHA-256 checksum file, so the download cannot be verified. Install refused."
        case .checksumMalformed:
            return "The release checksum file could not be read. Install refused."
        case .checksumMismatch:
            return "The downloaded update does not match its published SHA-256 checksum. Install refused."
        case .signatureInvalid(let detail):
            return "The downloaded app failed code-signature verification (\(detail)). Install refused."
        }
    }
}

enum UpdateVerifier {

    // MARK: - Checksum

    /// Streams the file through SHA-256 and returns lowercase hex.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a checksum file: either a bare hex digest, or `shasum` lines
    /// (`<hex>  <name>`). With several lines, the one naming `assetName` wins.
    static func parseChecksum(_ text: String, assetName: String) -> String? {
        func isHex64(_ s: String) -> Bool {
            s.count == 64 && s.allSatisfy { $0.isHexDigit }
        }
        var fallback: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let first = parts.first, isHex64(first) else { continue }
            if parts.count >= 2 {
                let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : parts[1]
                if (name as NSString).lastPathComponent == assetName { return first.lowercased() }
            } else {
                fallback = first.lowercased()
            }
        }
        return fallback
    }

    /// Throws unless `file` hashes to the digest in `checksumText`.
    static func verifyChecksum(file: URL, checksumText: String?, assetName: String) throws {
        guard let checksumText else { throw UpdateVerificationError.checksumMissing }
        guard let expected = parseChecksum(checksumText, assetName: assetName) else {
            throw UpdateVerificationError.checksumMalformed
        }
        let actual = try sha256Hex(of: file)
        guard actual == expected else {
            throw UpdateVerificationError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    // MARK: - Code signature

    /// Runs `codesign --verify --deep --strict <app>`.
    static func verifyCodeSignature(of app: URL) async throws {
        let (status, output) = await runCodesign(arguments: ["--verify", "--deep", "--strict", app.path])
        guard status == 0 else {
            throw UpdateVerificationError.signatureInvalid(
                output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200).description)
        }
    }

    private static func runCodesign(arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            proc.arguments = arguments
            let pipe = Pipe()
            proc.standardError = pipe
            proc.standardOutput = pipe
            do { try proc.run() } catch {
                cont.resume(returning: (-1, error.localizedDescription)); return
            }
            // Drain before waiting so a full pipe cannot stall the child.
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
