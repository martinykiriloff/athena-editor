// TestingView.swift
// Athena — Testing sidebar: files -> tests with state, run all / file / test / failed.
// Swift 6, strict concurrency.

import SwiftUI

struct TestingView: View {
    @Environment(AppState.self) private var appState

    private var center: TestCenter { appState.testCenter }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if center.files.isEmpty {
                empty
            } else {
                List {
                    ForEach(center.files) { node in
                        Section {
                            ForEach(node.declarations) { decl in
                                row(node: node, decl: decl)
                            }
                        } header: {
                            fileHeader(node)
                        }
                    }
                }
                .listStyle(.plain)
            }
            if let error = center.lastError {
                Text(error)
                    .font(.system(size: appState.sf(11)))
                    .foregroundColor(.red)
                    .padding(appState.sf(8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: appState.workspace?.rootURL) { await appState.refreshTests() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: appState.sf(6)) {
            Button { appState.runAllTests() } label: { Image(systemName: "play.fill") }
                .help("Run All Tests")
                .disabled(center.isRunning || center.files.isEmpty)
            Button { appState.rerunFailedTests() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Re-run Failed Tests")
                .disabled(center.isRunning || center.failedResults.isEmpty)
            Button { appState.stopTests() } label: { Image(systemName: "stop.fill") }
                .help("Stop")
                .disabled(!center.isRunning)
            Button { Task { await appState.refreshTests() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Spacer()
            if center.isRunning {
                ProgressView().controlSize(.small)
            } else if let summary = center.lastSummary {
                Text(summary).font(.system(size: appState.sf(11))).foregroundColor(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, appState.sf(10))
        .padding(.vertical, appState.sf(6))
    }

    private var empty: some View {
        VStack(spacing: appState.sf(6)) {
            Text("No tests found")
                .font(.system(size: appState.sf(13)))
                .foregroundColor(.secondary)
            Text("Jest, Vitest, pytest and swift test are detected from package.json, config files and Package.swift.")
                .font(.system(size: appState.sf(11)))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(appState.sf(16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Rows

    private func fileHeader(_ node: TestFileNode) -> some View {
        HStack {
            Button {
                Task { await appState.openFile(URL(fileURLWithPath: node.path)) }
            } label: {
                Text("\(URL(fileURLWithPath: node.path).lastPathComponent) · \(node.framework.displayName)")
                    .font(.system(size: appState.sf(11), weight: .semibold))
            }
            .buttonStyle(.plain)
            Spacer()
            Button { appState.runTests(.file(path: node.path)) } label: { Image(systemName: "play") }
                .buttonStyle(.borderless)
                .help("Run File")
                .disabled(center.isRunning)
        }
    }

    private func row(node: TestFileNode, decl: TestDeclaration) -> some View {
        let status = center.status(path: node.path, fullName: decl.fullName)
        return HStack(spacing: appState.sf(6)) {
            statusIcon(status)
            Text(decl.title)
                .font(.system(size: appState.sf(12), weight: decl.isSuite ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
            Button {
                appState.runTests(decl.isSuite ? .file(path: node.path) : .test(path: node.path, fullName: decl.fullName))
            } label: { Image(systemName: "play") }
                .buttonStyle(.borderless)
                .disabled(center.isRunning)
        }
        .padding(.leading, CGFloat(decl.depth) * appState.sf(12))
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await appState.navigateTo(DefinitionLocation(
                    fileURL: URL(fileURLWithPath: node.path), line: decl.line, character: 1))
            }
        }
        .help(center.results[TestCenter.key(node.path, decl.fullName)]?.message ?? decl.fullName)
    }

    @ViewBuilder
    private func statusIcon(_ status: TestStatus) -> some View {
        switch status {
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(.red)
        case .running: ProgressView().controlSize(.mini)
        case .skipped: Image(systemName: "minus.circle").foregroundColor(.secondary)
        case .unknown: Image(systemName: "circle").foregroundColor(.secondary)
        }
    }
}
