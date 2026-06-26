// ScriptsPanelView.swift
// Athena — bottom-panel "Scripts" tab: package + script picker with ▶ Run / ■ Stop.
// Swift 6, strict concurrency.

import SwiftUI

struct ScriptsPanelView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.npmPackages.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()
                outputArea
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: appState.sf(28)))
                .foregroundColor(.secondary)
            Text("No package.json found in workspace.")
                .font(.system(size: appState.sf(13)))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {

            // Package selector — only shown when workspace has multiple packages.
            if appState.npmPackages.count > 1 {
                Picker("", selection: Bindable(appState).selectedNPMPackageId) {
                    ForEach(appState.npmPackages) { pkg in
                        Text(pkg.name).tag(Optional(pkg.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 130)
                .font(.system(size: appState.sf(12)))
                .help("Select package")
            }

            // Script selector.
            Picker("", selection: Bindable(appState).selectedNPMScriptName) {
                Text("Select script…").tag(String?.none)
                ForEach(appState.selectedNPMPackage?.scripts ?? []) { script in
                    Text(script.name).tag(Optional(script.name))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 190)
            .font(.system(size: appState.sf(12)))
            .help("Select npm script")

            // Package manager badge (npm / pnpm / yarn).
            if let pm = appState.selectedNPMPackage?.packageManager {
                Text(pm.rawValue)
                    .font(.system(size: appState.sf(10), weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Spacer()

            // Run / Stop button.
            if appState.selectedScriptIsRunning {
                Button {
                    if let pkg  = appState.selectedNPMPackage,
                       let name = appState.selectedNPMScriptName {
                        appState.stopNPMScript(key: pkg.id + ":" + name)
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: appState.sf(12)))
                        .foregroundColor(.red)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("Stop script")
            } else {
                Button {
                    if let pkg  = appState.selectedNPMPackage,
                       let name = appState.selectedNPMScriptName {
                        appState.runNPMScript(name, in: pkg)
                    }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: appState.sf(12)))
                        .foregroundColor(appState.selectedNPMScriptName == nil ? .secondary : .green)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(appState.selectedNPMScriptName == nil)
                .help("Run script")
            }

            // Clear output.
            if !appState.scriptOutput.isEmpty {
                Button {
                    appState.scriptOutput = ""
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: appState.sf(11)))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("Clear output")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: Output

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(appState.scriptOutput.isEmpty
                     ? "[Athena] Select a script and press ▶ to run it.\n"
                     : appState.scriptOutput)
                    .font(.system(size: appState.sf(12), design: .monospaced))
                    .foregroundColor(appState.scriptOutput.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("scriptsEnd")
            }
            .onChange(of: appState.scriptOutput) { _, _ in
                proxy.scrollTo("scriptsEnd", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("scriptsEnd", anchor: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
