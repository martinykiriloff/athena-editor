// HTTPResponseView.swift
// Athena — bottom-panel viewer for the last .http response: status, time, size, headers, pretty body, copy.
// Swift 6, strict concurrency.

import SwiftUI

struct HTTPResponseView: View {
    @Environment(AppState.self) private var appState
    @State private var showHeaders = false

    var body: some View {
        let center = appState.requestCenter
        Group {
            if center.httpIsSending {
                ProgressView("Sending…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = center.httpError {
                ContentUnavailableView("Request failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let r = center.httpResponse {
                content(r)
            } else {
                ContentUnavailableView("No response yet", systemImage: "paperplane",
                                       description: Text("Press ⌘↩ in a .http file, or click Send Request."))
            }
        }
    }

    private func content(_ r: HTTPResponseResult) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: appState.sf(12)) {
                Text("\(r.statusCode) \(r.statusText)")
                    .font(.system(size: appState.sf(12), weight: .semibold))
                    .foregroundStyle(statusColor(r.statusCode))
                Text(String(format: "%.0f ms", r.durationMs))
                Text(HTTPClientService.formatSize(r.byteCount))
                if let type = r.contentType { Text(type).lineLimit(1) }
                Spacer()
                Picker("", selection: $showHeaders) {
                    Text("Body").tag(false)
                    Text("Headers (\(r.headers.count))").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: appState.sf(190))
                Button { appState.copyHTTPResponseBody() } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy response body")
            }
            .font(.system(size: appState.sf(11)))
            .foregroundStyle(.secondary)
            .padding(.horizontal, appState.sf(10))
            .padding(.vertical, appState.sf(5))
            Divider()
            ScrollView([.vertical, .horizontal]) {
                Group {
                    if showHeaders {
                        VStack(alignment: .leading, spacing: appState.sf(2)) {
                            ForEach(Array(r.headers.enumerated()), id: \.offset) { _, h in
                                Text("\(h.name): ").bold() + Text(h.value)
                            }
                        }
                    } else {
                        Text(r.prettyBody.isEmpty ? "(empty body)" : r.prettyBody)
                    }
                }
                .font(.system(size: appState.sf(12), design: .monospaced))
                .textSelection(.enabled)
                .padding(appState.sf(10))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .orange
        default: return .red
        }
    }
}
