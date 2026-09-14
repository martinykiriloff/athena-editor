// NPMScriptsView.swift
// Athena — sidebar panel listing npm/pnpm/yarn scripts from package.json.
// Swift 6, strict concurrency.

import SwiftUI

// MARK: - NPMScriptsView

struct NPMScriptsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if appState.workspace == nil {
                emptyState(message: "Open a folder to see scripts", icon: "shippingbox")
            } else if appState.npmPackages.isEmpty {
                emptyState(message: "No package.json found", icon: "shippingbox")
            } else {
                packageList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: appState.workspace?.rootURL) {
            await appState.discoverNPMPackages()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 0) {
            Spacer()
            Button {
                Task { await appState.discoverNPMPackages() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: appState.sf(13)))
                    .foregroundColor(.secondary)
                    .frame(width: appState.sf(28), height: appState.sf(28))
            }
            .buttonStyle(.plain)
            .help("Refresh scripts")

            if !appState.scriptOutput.isEmpty {
                Button {
                    appState.scriptOutput = ""
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: appState.sf(13)))
                        .foregroundColor(.secondary)
                        .frame(width: appState.sf(28), height: appState.sf(28))
                }
                .buttonStyle(.plain)
                .help("Clear output")
            }
        }
        .padding(.horizontal, appState.sf(6))
        .frame(height: appState.sf(28))
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Empty state

    private func emptyState(message: String, icon: String) -> some View {
        VStack(spacing: appState.sf(8)) {
            Image(systemName: icon)
                .font(.system(size: appState.sf(28)))
                .foregroundColor(.secondary)
            Text(message)
                .font(.system(size: appState.sf(12)))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(appState.sf(16))
    }

    // MARK: Package list

    private var packageList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(appState.npmPackages) { pkg in
                    PackageGroupView(package: pkg)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PackageGroupView

private struct PackageGroupView: View {
    let package: NPMPackageInfo
    @Environment(AppState.self) private var appState
    @State private var isExpanded: Bool = true

    private var pmColor: Color {
        switch package.packageManager {
        case .npm:  return Color(red: 0.78, green: 0.06, blue: 0.06)
        case .pnpm: return Color(red: 0.95, green: 0.62, blue: 0.07)
        case .yarn: return Color(red: 0.12, green: 0.56, blue: 0.87)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: appState.sf(6)) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: appState.sf(10)))
                        .foregroundColor(.secondary)
                        .frame(width: appState.sf(12))

                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: appState.sf(12)))
                        .foregroundColor(pmColor)

                    Text(package.name)
                        .font(.system(size: appState.sf(12), weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(package.packageManager.rawValue)
                        .font(.system(size: appState.sf(10)))
                        .foregroundColor(pmColor)
                        .padding(.horizontal, appState.sf(4))
                        .padding(.vertical, appState.sf(1))
                        .background(pmColor.opacity(0.15))
                        .cornerRadius(appState.sf(3))

                    Spacer()

                    Text("\(package.scripts.count)")
                        .font(.system(size: appState.sf(10)))
                        .foregroundColor(.secondary)
                        .padding(.trailing, appState.sf(4))
                }
                .padding(.horizontal, appState.sf(12))
                .frame(height: appState.sf(30))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(package.scripts) { script in
                    ScriptRowView(script: script, package: package)
                }
            }

            Divider()
        }
    }
}

// MARK: - ScriptRowView

private struct ScriptRowView: View {
    let script: NPMScript
    let package: NPMPackageInfo
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    private var runKey: String { package.id + ":" + script.name }
    private var isRunning: Bool { appState.runningScriptKeys.contains(runKey) }

    var body: some View {
        HStack(spacing: appState.sf(6)) {
            // indentation
            Color.clear.frame(width: appState.sf(28))

            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: appState.sf(8)))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: appState.sf(2)) {
                Text(script.name)
                    .font(.system(size: appState.sf(12)))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if isHovering || isRunning {
                    Text(script.command)
                        .font(.system(size: appState.sf(10), design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if isHovering || isRunning {
                Button {
                    if isRunning {
                        appState.stopNPMScript(key: runKey)
                    } else {
                        appState.runNPMScript(script.name, in: package)
                    }
                } label: {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: appState.sf(11)))
                        .foregroundColor(isRunning ? .red : Color.green)
                        .frame(width: appState.sf(26), height: appState.sf(26))
                        .background(
                            RoundedRectangle(cornerRadius: appState.sf(4))
                                .fill((isRunning ? Color.red : Color.green).opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .help(isRunning ? "Stop \(script.name)" : "Run \(script.name)")
                .padding(.trailing, appState.sf(4))
            }
        }
        .padding(.horizontal, appState.sf(12))
        .frame(minHeight: appState.sf(28))
        .padding(.vertical, (isHovering || isRunning) ? appState.sf(4) : 0)
        .background(
            isRunning
                ? Color.green.opacity(0.08)
                : (isHovering ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.25) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.1), value: isHovering)
        .animation(.easeInOut(duration: 0.1), value: isRunning)
        .onHover { isHovering = $0 }
    }
}
