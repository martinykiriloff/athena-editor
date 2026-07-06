// ClaudePanel.swift — Claude AI right panel: account switcher, command palette, chat.

import SwiftUI

// MARK: - PanelCommand

private struct PanelCommand: Identifiable {
    let id:          String
    let trigger:     String
    let icon:        String
    let title:       String
    let description: String
    let category:    String
    let isBuiltIn:   Bool

    // ── All commands from https://code.claude.com/docs/en/commands ──────────────
    static let all: [PanelCommand] = [

        // ── Session ──────────────────────────────────────────────────────────
        PanelCommand(id: "clear",      trigger: "/clear",      icon: "trash",                                title: "Clear",         description: "Start new conversation, keep memory",         category: "Session", isBuiltIn: true),
        PanelCommand(id: "compact",    trigger: "/compact",    icon: "arrow.down.right.and.arrow.up.left",   title: "Compact",       description: "Summarize conversation to free context",      category: "Session", isBuiltIn: false),
        PanelCommand(id: "context",    trigger: "/context",    icon: "chart.bar",                            title: "Context",        description: "Visualize context window usage",             category: "Session", isBuiltIn: false),
        PanelCommand(id: "focus",      trigger: "/focus",      icon: "eye",                                  title: "Focus",          description: "Toggle focus view (last prompt + response)", category: "Session", isBuiltIn: false),
        PanelCommand(id: "recap",      trigger: "/recap",      icon: "text.alignleft",                       title: "Recap",          description: "One-line summary of current session",        category: "Session", isBuiltIn: false),
        PanelCommand(id: "rewind",     trigger: "/rewind",     icon: "arrow.uturn.backward",                 title: "Rewind",         description: "Roll back conversation/code to checkpoint",  category: "Session", isBuiltIn: false),
        PanelCommand(id: "branch",     trigger: "/branch",     icon: "arrow.triangle.branch",                title: "Branch",         description: "Fork conversation to try a different path",  category: "Session", isBuiltIn: false),
        PanelCommand(id: "fork",       trigger: "/fork",       icon: "arrow.turn.down.right",               title: "Fork",           description: "Spawn background subagent on directive",     category: "Session", isBuiltIn: false),
        PanelCommand(id: "resume",     trigger: "/resume",     icon: "arrow.clockwise",                      title: "Resume",         description: "Resume a previous conversation",             category: "Session", isBuiltIn: false),
        PanelCommand(id: "rename",     trigger: "/rename",     icon: "pencil",                               title: "Rename",         description: "Rename current session",                     category: "Session", isBuiltIn: false),
        PanelCommand(id: "export",     trigger: "/export",     icon: "square.and.arrow.up",                  title: "Export",         description: "Export conversation as plain text",          category: "Session", isBuiltIn: false),
        PanelCommand(id: "copy",       trigger: "/copy",       icon: "doc.on.doc",                           title: "Copy",           description: "Copy last assistant response to clipboard",  category: "Session", isBuiltIn: false),
        PanelCommand(id: "btw",        trigger: "/btw",        icon: "bubble.left",                          title: "BTW",            description: "Ask a side question without bloating history",category: "Session", isBuiltIn: false),
        PanelCommand(id: "plan",       trigger: "/plan",       icon: "list.bullet.clipboard",                title: "Plan",           description: "Enter plan mode before a large change",      category: "Session", isBuiltIn: false),
        PanelCommand(id: "goal",       trigger: "/goal",       icon: "target",                               title: "Goal",           description: "Set goal — Claude works until condition met", category: "Session", isBuiltIn: false),
        PanelCommand(id: "background", trigger: "/background", icon: "rectangle.stack",                      title: "Background",     description: "Detach session to run as background agent",  category: "Session", isBuiltIn: false),
        PanelCommand(id: "tasks",      trigger: "/tasks",      icon: "list.dash",                            title: "Tasks",          description: "View and manage background tasks",           category: "Session", isBuiltIn: false),
        PanelCommand(id: "workflows",  trigger: "/workflows",  icon: "arrow.2.circlepath",                   title: "Workflows",      description: "Watch running and completed workflows",      category: "Session", isBuiltIn: false),
        PanelCommand(id: "stop",       trigger: "/stop",       icon: "stop.circle",                          title: "Stop",           description: "Stop the current background session",        category: "Session", isBuiltIn: false),
        PanelCommand(id: "loop",       trigger: "/loop",       icon: "repeat",                               title: "Loop",           description: "Run a prompt repeatedly (self-paced)",       category: "Session", isBuiltIn: false),

        // ── Code ─────────────────────────────────────────────────────────────
        PanelCommand(id: "review",         trigger: "/review",         icon: "checkmark.seal",            title: "Review",          description: "Review current file or a pull request",        category: "Code", isBuiltIn: false),
        PanelCommand(id: "code-review",    trigger: "/code-review",    icon: "magnifyingglass.circle",    title: "Code Review",     description: "Review diff for bugs and cleanups",            category: "Code", isBuiltIn: false),
        PanelCommand(id: "security-review",trigger: "/security-review",icon: "lock.shield",               title: "Security Review", description: "Audit pending changes for vulnerabilities",    category: "Code", isBuiltIn: false),
        PanelCommand(id: "simplify",       trigger: "/simplify",       icon: "wand.and.sparkles",         title: "Simplify",        description: "Cleanup and simplify changed code",            category: "Code", isBuiltIn: false),
        PanelCommand(id: "diff",           trigger: "/diff",           icon: "arrow.left.arrow.right",    title: "Diff",            description: "View uncommitted changes interactively",       category: "Code", isBuiltIn: false),
        PanelCommand(id: "explain",        trigger: "/explain",        icon: "text.magnifyingglass",      title: "Explain",         description: "Explain current file in detail",               category: "Code", isBuiltIn: false),
        PanelCommand(id: "fix",            trigger: "/fix",            icon: "wrench.and.screwdriver",    title: "Fix",             description: "Find and fix bugs in current file",            category: "Code", isBuiltIn: false),
        PanelCommand(id: "refactor",       trigger: "/refactor",       icon: "arrow.triangle.2.circlepath",title: "Refactor",       description: "Suggest refactoring improvements",             category: "Code", isBuiltIn: false),
        PanelCommand(id: "tests",          trigger: "/tests",          icon: "checklist",                 title: "Tests",           description: "Generate tests for current file",              category: "Code", isBuiltIn: false),
        PanelCommand(id: "docs",           trigger: "/docs",           icon: "doc.text",                  title: "Docs",            description: "Generate documentation for current file",      category: "Code", isBuiltIn: false),
        PanelCommand(id: "run",            trigger: "/run",            icon: "play.circle",               title: "Run",             description: "Launch and drive project app to verify change", category: "Code", isBuiltIn: false),
        PanelCommand(id: "verify",         trigger: "/verify",         icon: "checkmark.circle",          title: "Verify",          description: "Confirm a code change does what it should",    category: "Code", isBuiltIn: false),
        PanelCommand(id: "debug",          trigger: "/debug",          icon: "ant.circle",                title: "Debug",           description: "Enable debug logging and troubleshoot",        category: "Code", isBuiltIn: false),
        PanelCommand(id: "deep-research",  trigger: "/deep-research",  icon: "globe.americas",            title: "Deep Research",   description: "Fan out web searches and synthesize a report", category: "Code", isBuiltIn: false),
        PanelCommand(id: "ultraplan",      trigger: "/ultraplan",      icon: "chart.xyaxis.line",         title: "Ultraplan",       description: "Draft plan in browser then execute remotely",  category: "Code", isBuiltIn: false),
        PanelCommand(id: "ultrareview",    trigger: "/ultrareview",    icon: "person.2.badge.gearshape",  title: "Ultrareview",     description: "Deep cloud multi-agent code review",           category: "Code", isBuiltIn: false),
        PanelCommand(id: "batch",          trigger: "/batch",          icon: "square.grid.3x3",           title: "Batch",           description: "Parallel codebase-wide changes via subagents", category: "Code", isBuiltIn: false),

        // ── Project ───────────────────────────────────────────────────────────
        PanelCommand(id: "init",              trigger: "/init",              icon: "sparkles",              title: "Init",            description: "Create CLAUDE.md project guide",                category: "Project", isBuiltIn: false),
        PanelCommand(id: "memory",            trigger: "/memory",            icon: "brain",                 title: "Memory",          description: "Edit CLAUDE.md and auto-memory entries",        category: "Project", isBuiltIn: false),
        PanelCommand(id: "commit",            trigger: "/commit",            icon: "arrow.up.circle",       title: "Commit",          description: "Generate git commit message (Conventional)",   category: "Project", isBuiltIn: false),
        PanelCommand(id: "doctor",            trigger: "/doctor",            icon: "stethoscope",           title: "Doctor",          description: "Diagnose Claude Code installation",            category: "Project", isBuiltIn: false),
        PanelCommand(id: "autofix-pr",        trigger: "/autofix-pr",        icon: "arrow.triangle.pull",   title: "Autofix PR",      description: "Auto-fix CI failures and review comments on PR",category: "Project", isBuiltIn: false),
        PanelCommand(id: "schedule",          trigger: "/schedule",          icon: "calendar.badge.clock",  title: "Schedule",        description: "Create cloud routines (runs on schedule)",     category: "Project", isBuiltIn: false),
        PanelCommand(id: "insights",          trigger: "/insights",          icon: "chart.line.uptrend.xyaxis",title: "Insights",     description: "Analyze Claude Code session patterns",         category: "Project", isBuiltIn: false),
        PanelCommand(id: "team-onboarding",   trigger: "/team-onboarding",   icon: "person.3",              title: "Team Onboarding", description: "Generate onboarding guide from usage history",  category: "Project", isBuiltIn: false),
        PanelCommand(id: "run-skill-generator",trigger: "/run-skill-generator",icon: "hammer",              title: "Skill Generator", description: "Teach /run how to build and launch app",       category: "Project", isBuiltIn: false),
        PanelCommand(id: "fewer-prompts",     trigger: "/fewer-permission-prompts",icon: "hand.raised.slash",title: "Fewer Prompts",  description: "Add allowlist to reduce permission prompts",   category: "Project", isBuiltIn: false),
        PanelCommand(id: "install-github-app",trigger: "/install-github-app",icon: "arrow.down.circle",    title: "GitHub App",      description: "Set up Claude GitHub Actions for a repo",      category: "Project", isBuiltIn: false),
        PanelCommand(id: "install-slack-app", trigger: "/install-slack-app", icon: "message",               title: "Slack App",       description: "Install Claude Slack app (opens OAuth flow)",  category: "Project", isBuiltIn: false),
        PanelCommand(id: "web-setup",         trigger: "/web-setup",         icon: "globe",                 title: "Web Setup",       description: "Connect GitHub to Claude Code on the web",     category: "Project", isBuiltIn: false),
        PanelCommand(id: "autofix-pr2",       trigger: "/autofix-pr",        icon: "arrow.triangle.pull",   title: "Autofix PR",      description: "Watch PR and push fixes on CI failure",        category: "Project", isBuiltIn: false),

        // ── Config ────────────────────────────────────────────────────────────
        PanelCommand(id: "config",        trigger: "/config",       icon: "gearshape",                  title: "Config",         description: "Open settings or set key=value directly",      category: "Config", isBuiltIn: false),
        PanelCommand(id: "model",         trigger: "/model",        icon: "cpu",                        title: "Model",          description: "Switch AI model (saves as default)",            category: "Config", isBuiltIn: true),
        PanelCommand(id: "effort",        trigger: "/effort",       icon: "slider.horizontal.3",        title: "Effort",         description: "Set reasoning effort: low/medium/high/max",    category: "Config", isBuiltIn: false),
        PanelCommand(id: "fast",          trigger: "/fast",         icon: "bolt.fill",                  title: "Fast",           description: "Toggle fast mode on or off",                   category: "Config", isBuiltIn: false),
        PanelCommand(id: "advisor",       trigger: "/advisor",      icon: "person.badge.plus",          title: "Advisor",        description: "Enable advisor model for guidance",             category: "Config", isBuiltIn: false),
        PanelCommand(id: "permissions",   trigger: "/permissions",  icon: "lock",                       title: "Permissions",    description: "Manage allow/ask/deny tool permission rules",  category: "Config", isBuiltIn: false),
        PanelCommand(id: "hooks",         trigger: "/hooks",        icon: "bolt",                       title: "Hooks",          description: "View hook configurations for tool events",     category: "Config", isBuiltIn: false),
        PanelCommand(id: "mcp",           trigger: "/mcp",          icon: "network",                    title: "MCP",            description: "Manage MCP server connections",                category: "Config", isBuiltIn: false),
        PanelCommand(id: "agents",        trigger: "/agents",       icon: "person.circle",              title: "Agents",         description: "Manage subagent configurations",               category: "Config", isBuiltIn: false),
        PanelCommand(id: "skills",        trigger: "/skills",       icon: "sparkle",                    title: "Skills",         description: "List available skills; toggle visibility",     category: "Config", isBuiltIn: false),
        PanelCommand(id: "plugin",        trigger: "/plugin",       icon: "puzzlepiece.extension",      title: "Plugin",         description: "Manage Claude Code plugins",                   category: "Config", isBuiltIn: false),
        PanelCommand(id: "reload-skills", trigger: "/reload-skills",icon: "arrow.clockwise",            title: "Reload Skills",  description: "Re-scan skill files without restarting",       category: "Config", isBuiltIn: false),
        PanelCommand(id: "reload-plugins",trigger: "/reload-plugins",icon: "arrow.clockwise.circle",   title: "Reload Plugins", description: "Reload active plugins to apply changes",       category: "Config", isBuiltIn: false),
        PanelCommand(id: "theme",         trigger: "/theme",        icon: "paintpalette",               title: "Theme",          description: "Change color theme",                           category: "Config", isBuiltIn: false),
        PanelCommand(id: "keybindings",   trigger: "/keybindings",  icon: "keyboard",                   title: "Keybindings",    description: "Open keyboard shortcuts file",                 category: "Config", isBuiltIn: false),
        PanelCommand(id: "sandbox",       trigger: "/sandbox",      icon: "cube",                       title: "Sandbox",        description: "Toggle sandbox mode",                          category: "Config", isBuiltIn: false),
        PanelCommand(id: "statusline",    trigger: "/statusline",   icon: "menubar.rectangle",          title: "Statusline",     description: "Configure terminal status line",               category: "Config", isBuiltIn: false),
        PanelCommand(id: "add-dir",       trigger: "/add-dir",      icon: "folder.badge.plus",          title: "Add Dir",        description: "Add a working directory for file access",      category: "Config", isBuiltIn: false),
        PanelCommand(id: "cd",            trigger: "/cd",           icon: "folder.fill",                title: "CD",             description: "Move session to a new working directory",      category: "Config", isBuiltIn: false),

        // ── Info ──────────────────────────────────────────────────────────────
        PanelCommand(id: "help",          trigger: "/help",          icon: "questionmark.circle",       title: "Help",           description: "Show help and available commands",             category: "Info", isBuiltIn: true),
        PanelCommand(id: "cost",          trigger: "/cost",          icon: "dollarsign.circle",         title: "Cost",           description: "Session cost and token usage",                 category: "Info", isBuiltIn: true),
        PanelCommand(id: "usage",         trigger: "/usage",         icon: "chart.pie",                 title: "Usage",          description: "Plan usage limits and activity stats",         category: "Info", isBuiltIn: false),
        PanelCommand(id: "status",        trigger: "/status",        icon: "info.circle",               title: "Status",         description: "Version, model, account, connectivity",        category: "Info", isBuiltIn: false),
        PanelCommand(id: "release-notes", trigger: "/release-notes", icon: "newspaper",                 title: "Release Notes",  description: "View changelog and version history",           category: "Info", isBuiltIn: false),
        PanelCommand(id: "feedback",      trigger: "/feedback",      icon: "envelope",                  title: "Feedback",       description: "Submit feedback or report a bug",              category: "Info", isBuiltIn: false),
        PanelCommand(id: "claude-api",    trigger: "/claude-api",    icon: "curlybraces",               title: "Claude API",     description: "Load Claude API reference for current language",category: "Info", isBuiltIn: false),
        PanelCommand(id: "powerup",       trigger: "/powerup",       icon: "bolt.circle",               title: "Powerup",        description: "Interactive lessons with animated demos",      category: "Info", isBuiltIn: false),
        PanelCommand(id: "login",         trigger: "/login",         icon: "person.badge.key",          title: "Login",          description: "Sign in to Anthropic account",                 category: "Info", isBuiltIn: false),
        PanelCommand(id: "logout",        trigger: "/logout",        icon: "rectangle.portrait.and.arrow.right", title: "Logout", description: "Sign out from Anthropic account",          category: "Info", isBuiltIn: false),
        PanelCommand(id: "upgrade",       trigger: "/upgrade",       icon: "arrow.up.circle.fill",      title: "Upgrade",        description: "Switch to a higher plan tier",                 category: "Info", isBuiltIn: false),
        PanelCommand(id: "usage-credits", trigger: "/usage-credits", icon: "creditcard",                title: "Usage Credits",  description: "Configure credits for when you hit a limit",   category: "Info", isBuiltIn: false),

        // ── Connect ───────────────────────────────────────────────────────────
        PanelCommand(id: "ide",            trigger: "/ide",            icon: "rectangle.badge.gearshape", title: "IDE",           description: "Manage IDE integrations and show status",       category: "Connect", isBuiltIn: false),
        PanelCommand(id: "desktop",        trigger: "/desktop",        icon: "desktopcomputer",           title: "Desktop",       description: "Continue session in Claude Code Desktop",       category: "Connect", isBuiltIn: false),
        PanelCommand(id: "remote-control", trigger: "/remote-control", icon: "dot.radiowaves.left.and.right",title: "Remote Control",description: "Enable remote control from claude.ai",     category: "Connect", isBuiltIn: false),
        PanelCommand(id: "remote-env",     trigger: "/remote-env",     icon: "server.rack",               title: "Remote Env",    description: "Set default cloud agent environment",          category: "Connect", isBuiltIn: false),
        PanelCommand(id: "teleport",       trigger: "/teleport",       icon: "arrow.down.to.line",        title: "Teleport",      description: "Pull a web session into this terminal",         category: "Connect", isBuiltIn: false),
        PanelCommand(id: "voice",          trigger: "/voice",          icon: "mic",                       title: "Voice",         description: "Toggle voice dictation (hold/tap/off)",         category: "Connect", isBuiltIn: false),
        PanelCommand(id: "chrome",         trigger: "/chrome",         icon: "safari",                    title: "Chrome",        description: "Configure Claude in Chrome settings",           category: "Connect", isBuiltIn: false),
        PanelCommand(id: "terminal-setup", trigger: "/terminal-setup", icon: "terminal",                  title: "Terminal Setup", description: "Configure terminal keybindings",              category: "Connect", isBuiltIn: false),
        PanelCommand(id: "mobile",         trigger: "/mobile",         icon: "iphone",                    title: "Mobile",        description: "Get QR code to download Claude mobile app",    category: "Connect", isBuiltIn: false),
        PanelCommand(id: "setup-bedrock",  trigger: "/setup-bedrock",  icon: "cube.transparent",          title: "Bedrock",       description: "Configure Amazon Bedrock authentication",       category: "Connect", isBuiltIn: false),
        PanelCommand(id: "setup-vertex",   trigger: "/setup-vertex",   icon: "triangle.tophalf.filled",   title: "Vertex AI",     description: "Configure Google Vertex AI authentication",     category: "Connect", isBuiltIn: false),
    ]

    static let categories: [String] = {
        var seen = Set<String>()
        var order: [String] = []
        for cmd in all {
            if seen.insert(cmd.category).inserted { order.append(cmd.category) }
        }
        return order
    }()
}

// MARK: - ClaudePanel

struct ClaudePanel: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""
    @State private var showCommands: Bool = false
    @State private var commandFilter: String = ""
    @State private var hoveredCommandId: String? = nil
    @State private var selectedCommandId: String? = nil
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            accountBar
            Divider()
            messageList
            Divider()
            inputArea
        }
        .overlay(alignment: .leading) { Divider() }
    }

    // MARK: Account switcher

    private var accountBar: some View {
        HStack(spacing: 6) {
            ForEach(ClaudeAccount.all) { account in
                AccountChip(
                    account: account,
                    isActive: appState.activeClaudeAccount == account
                ) {
                    Task { await appState.switchClaudeAccount(account) }
                }
            }
            Spacer()
            if !appState.claudeMessages.isEmpty {
                Button {
                    appState.claudeMessages = []
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: appState.sf(11)))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear conversation")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if appState.claudeMessages.isEmpty {
                        emptyState
                    } else {
                        ForEach(appState.claudeMessages) { msg in
                            MessageRow(message: msg)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: appState.claudeMessages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: appState.claudeMessages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: appState.sf(28)))
                .foregroundStyle(.tertiary)
            Text("Ask Claude anything")
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(.secondary)
            Text("Type / for commands")
                .font(.system(size: appState.sf(11)))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
    }

    // MARK: Input area

    private var inputArea: some View {
        VStack(spacing: 0) {
            if showCommands {
                commandPalette
                Divider()
            }
            inputBar
        }
    }

    // MARK: Command palette

    private var filteredCommands: [PanelCommand] {
        guard !commandFilter.isEmpty else { return PanelCommand.all }
        let q = commandFilter.lowercased()
        return PanelCommand.all.filter {
            $0.trigger.contains(q)
                || $0.title.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.category.lowercased().contains(q)
        }
    }

    private var visibleCommands: [PanelCommand] {
        commandFilter.isEmpty ? PanelCommand.all : filteredCommands
    }

    private func moveSelection(_ delta: Int) {
        let cmds = visibleCommands
        guard !cmds.isEmpty else { return }
        if let current = selectedCommandId,
           let idx = cmds.firstIndex(where: { $0.id == current }) {
            selectedCommandId = cmds[(idx + delta + cmds.count) % cmds.count].id
        } else {
            selectedCommandId = delta > 0 ? cmds.first?.id : cmds.last?.id
        }
    }

    private var commandPalette: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    if commandFilter.isEmpty {
                        // Grouped by category
                        ForEach(PanelCommand.categories, id: \.self) { cat in
                            let cmds = PanelCommand.all.filter { $0.category == cat }
                            Section {
                                ForEach(cmds) { cmd in
                                    commandRow(cmd)
                                    Divider().padding(.leading, 38)
                                }
                            } header: {
                                Text(cat.uppercased())
                                    .font(.system(size: appState.sf(9), weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Color(nsColor: .windowBackgroundColor))
                            }
                        }
                    } else {
                        // Flat filtered list
                        ForEach(filteredCommands) { cmd in
                            commandRow(cmd)
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            .background(Color(nsColor: .controlBackgroundColor))
            .onChange(of: selectedCommandId) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    private func commandRow(_ cmd: PanelCommand) -> some View {
        let highlighted = hoveredCommandId == cmd.id || selectedCommandId == cmd.id
        return Button {
            selectCommand(cmd)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: cmd.icon)
                    .font(.system(size: appState.sf(12)))
                    .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
                    .frame(width: 18, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(cmd.trigger)
                            .font(.system(size: appState.sf(11), design: .monospaced))
                            .foregroundStyle(.primary)
                        if cmd.isBuiltIn {
                            Text("built-in")
                                .font(.system(size: appState.sf(9), weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                    Text(cmd.description)
                        .font(.system(size: appState.sf(10)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(highlighted ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hoveredCommandId = $0 ? cmd.id : nil }
        .id(cmd.id)
    }

    // MARK: Input bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Claude… (/ for commands)", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: appState.sf(13)))
                .lineLimit(1...8)
                .focused($inputFocused)
                .onChange(of: inputText) { _, new in
                    if new.hasPrefix("/") {
                        showCommands = true
                        commandFilter = String(new.dropFirst())
                        selectedCommandId = visibleCommands.first?.id
                    } else {
                        showCommands = false
                        commandFilter = ""
                        selectedCommandId = nil
                    }
                }
                .onKeyPress(.upArrow) {
                    guard showCommands else { return .ignored }
                    moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard showCommands else { return .ignored }
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard showCommands,
                          let id = selectedCommandId,
                          let cmd = visibleCommands.first(where: { $0.id == id })
                    else { return .ignored }
                    selectCommand(cmd)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if showCommands {
                        showCommands = false
                        selectedCommandId = nil
                        return .handled
                    }
                    return .ignored
                }

            Button {
                if appState.claudeIsStreaming {
                    Task {
                        await appState.claudeCLIService.abort()
                        appState.claudeIsStreaming = false
                    }
                } else {
                    submit()
                }
            } label: {
                Image(systemName: appState.claudeIsStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: appState.sf(20)))
                    .foregroundStyle(sendButtonColor)
            }
            .buttonStyle(.plain)
            .disabled(!appState.claudeIsStreaming && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var sendButtonColor: Color {
        if appState.claudeIsStreaming { return .red }
        return inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .accentColor
    }

    // MARK: Actions

    private func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        showCommands = false
        commandFilter = ""
        inputText = ""
        Task { await appState.sendClaudeMessage(text) }
    }

    private func selectCommand(_ cmd: PanelCommand) {
        showCommands = false
        commandFilter = ""
        inputText = ""

        switch cmd.id {

        // ── In-app handlers ──────────────────────────────────────────────────
        case "clear":
            appState.claudeMessages = []

        case "cost":
            let chars = appState.claudeMessages.reduce(0) { $0 + $1.content.count }
            let est   = chars / 4
            let info  = "Estimated tokens in conversation: ~\(est.formatted()) tokens"
            appState.claudeMessages.append(ClaudeMessage(role: .assistant, content: info))

        case "model":
            let acc  = appState.activeClaudeAccount
            let info = "**Account:** \(acc.name)\n**Command:** `\(acc.command)`"
            appState.claudeMessages.append(ClaudeMessage(role: .assistant, content: info))

        case "help":
            let grouped = PanelCommand.categories.map { cat -> String in
                let cmds = PanelCommand.all.filter { $0.category == cat }
                let lines = cmds.map { "  **\($0.trigger)** — \($0.description)" }.joined(separator: "\n")
                return "**\(cat)**\n\(lines)"
            }.joined(separator: "\n\n")
            appState.claudeMessages.append(ClaudeMessage(role: .assistant, content: "All available commands:\n\n\(grouped)"))

        // ── Prompt builders ──────────────────────────────────────────────────
        default:
            if let prompt = buildPrompt(for: cmd) {
                Task { await appState.sendClaudeMessage(prompt) }
            }
        }
    }

    private func buildPrompt(for cmd: PanelCommand) -> String? {
        let fileName = appState.focusedTab?.title ?? "the active file"
        let content  = appState.focusedTab?.content ?? ""
        let snippet  = String(content.prefix(8000))
        let hasFile  = !content.isEmpty
        let fileBlock = hasFile ? "\n\n```\n\(snippet)\n```" : ""
        let workspace = appState.workspace?.rootURL.lastPathComponent ?? "this project"

        switch cmd.id {

        // ── File-context commands ────────────────────────────────────────────
        case "review":
            return "Review `\(fileName)` for bugs, issues, and improvements:\(fileBlock)"
        case "code-review":
            return "Review the current git diff for correctness bugs, simplification opportunities, and efficiency cleanups in \(workspace). Run `git diff HEAD` first."
        case "security-review":
            return "Audit pending changes in \(workspace) for security vulnerabilities — injection, auth issues, data exposure, and OWASP Top 10. Run `git diff HEAD` first."
        case "simplify":
            return "Review changed code in \(workspace) for cleanup — reuse of existing helpers, simplification, and efficiency. Run `git diff HEAD` first."
        case "explain":
            return "Explain what `\(fileName)` does, how it works, and any important design decisions:\(fileBlock)"
        case "fix":
            return "Identify and fix any bugs in `\(fileName)`:\(fileBlock)"
        case "refactor":
            return "Suggest concrete refactoring improvements for `\(fileName)` — clarity, duplication, naming, structure:\(fileBlock)"
        case "tests":
            return "Write comprehensive tests for `\(fileName)`, covering happy path and edge cases:\(fileBlock)"
        case "docs":
            return "Write clear documentation — docstrings and module-level overview — for `\(fileName)`:\(fileBlock)"
        case "debug":
            return "Help me debug `\(fileName)`. Enable debug logging and analyze any issues:\(fileBlock)"

        // ── Project commands ─────────────────────────────────────────────────
        case "commit":
            return "Generate a concise git commit message following Conventional Commits (feat/fix/chore/docs/refactor/test) for the staged changes in \(workspace). Run `git diff --cached` first."
        case "init":
            return "Create a CLAUDE.md file for \(workspace). Include: project overview, build/run commands, key architecture decisions, directory structure, coding conventions, and important context for an AI assistant."
        case "doctor":
            return "Diagnose the Claude Code installation and environment for \(workspace): check dependencies, config files, missing tools, environment variables, and suggest fixes."
        case "batch":
            return "I need large-scale changes across \(workspace). Research the codebase, decompose the work into independent units, and present a plan before executing in parallel."
        case "autofix-pr", "autofix-pr2":
            return "Watch the open PR for \(workspace) and push fixes when CI fails or reviewers leave comments. Start with `gh pr view` to detect the open PR."
        case "schedule":
            return "Help me create a scheduled routine for \(workspace). What task should run on a schedule, and how often?"
        case "loop":
            return "Run this task repeatedly for \(workspace) until I stop you: "
        case "insights":
            return "Analyze Claude Code usage for \(workspace): which areas are touched most, interaction patterns, and friction points."
        case "team-onboarding":
            return "Generate a team onboarding guide for \(workspace) from my Claude Code usage history. Summarize the key workflows, commands used, and conventions a new teammate should know."
        case "run-skill-generator":
            return "Teach /run how to build, launch, and drive \(workspace) from a clean environment by writing a per-project skill file."
        case "fewer-prompts":
            return "Scan my transcripts for common read-only Bash and MCP tool calls in \(workspace), then add a prioritized allowlist to .claude/settings.json to reduce permission prompts."
        case "install-github-app":
            return "Set up the Claude GitHub Actions app for \(workspace). Walk me through selecting a repo and configuring the integration."
        case "install-slack-app":
            return "Help me install the Claude Slack app and configure it for my workspace."
        case "web-setup":
            return "Connect my GitHub account to Claude Code on the web using local gh CLI credentials."
        case "ultraplan":
            return "Draft an ultraplan for the next major task in \(workspace). Include phases, risks, and open questions. I'll review and approve before execution."
        case "ultrareview":
            return "Run a deep multi-agent code review on the current branch in \(workspace). Check correctness, security, performance, and code quality."
        case "run":
            return "Launch and drive the \(workspace) app to verify the last change is working correctly in the running app, not just in tests."
        case "verify":
            return "Confirm the last code change in \(workspace) does what it should: build the app, run it, and observe the result."
        case "deep-research":
            return "Research question: "

        // ── Session commands ─────────────────────────────────────────────────
        case "compact":
            return "Please summarize our conversation so far into a compact form, preserving all key decisions, code snippets, and context."
        case "context":
            return "Show me a breakdown of what's consuming the most context in this conversation, and suggest how to optimize it."
        case "focus":
            return "Summarize the most recent task and result in one sentence."
        case "recap":
            return "Give me a one-line summary of what we've accomplished in this session."
        case "rewind":
            return "I want to rewind to an earlier point. Summarize the major checkpoints in our conversation so I can choose where to go back."
        case "branch":
            return "I want to try a different approach from here. Summarize the current state so I can fork the conversation."
        case "fork":
            return "I want to delegate a side task. What are you working on currently and what should the forked subagent focus on?"
        case "resume":
            return "List the most recent sessions available to resume, with a brief description of each."
        case "rename":
            return "Suggest a concise name for this session based on what we've been working on."
        case "export":
            return "Summarize this conversation in a format suitable for export: key decisions, code changes, and next steps."
        case "copy":
            return "Here is a copy of my last response above — let me know if you need any part elaborated."
        case "btw":
            return "Quick aside: "
        case "plan":
            return "Let's plan the next task. Enter plan mode: describe the goal and we'll outline the approach before making any changes."
        case "goal":
            return "Set a goal: Claude will keep working until this condition is met. What should the success condition be?"
        case "background":
            return "The current session should run as a background agent. What should it focus on while I do other work?"
        case "tasks":
            return "List all currently running background tasks and their status."
        case "workflows":
            return "List all running and recently completed workflows with their progress."

        // ── Config commands ──────────────────────────────────────────────────
        case "config":
            return "Show me the current Claude Code settings and help me adjust them."
        case "effort":
            return "What reasoning effort level is currently set, and what are the available options (low/medium/high/xhigh/max)?"
        case "fast":
            return "Toggle fast mode. What is the current fast mode status?"
        case "advisor":
            return "Enable the advisor model to consult a second model for guidance at key moments. Which model options are available?"
        case "permissions":
            return "Show me the current tool permission rules (allow/ask/deny) for this project and help me manage them."
        case "hooks":
            return "Show me the current hook configurations for tool events in this project."
        case "mcp":
            return "List all MCP server connections and their current status."
        case "agents":
            return "List all configured subagents and their capabilities."
        case "skills":
            return "List all available skills sorted by name. Show which are visible and which are hidden."
        case "plugin":
            return "List all installed Claude Code plugins and their status."
        case "reload-skills":
            return "Re-scan skill and command directories to pick up any new or changed skills."
        case "reload-plugins":
            return "Reload all active plugins to apply pending changes."
        case "theme":
            return "Show available color themes (dark, light, ANSI, colorblind) and help me choose one."
        case "keybindings":
            return "Show my keyboard shortcuts configuration file and available key bindings."
        case "sandbox":
            return "Toggle sandbox mode. What is the current sandbox status?"
        case "statusline":
            return "Help me configure the Claude Code status line. What shell am I using and what info should it show?"
        case "add-dir":
            return "I want to add a directory to the session. Which path should I add?"
        case "cd":
            return "I want to move this session to a different directory. Which path?"

        // ── Info commands ────────────────────────────────────────────────────
        case "usage":
            return "Show session cost, plan usage limits, and activity stats broken down by skill, subagent, and MCP server."
        case "status":
            return "Show current Claude Code version, model, account, and connectivity status."
        case "release-notes":
            return "What are the most recent Claude Code release notes? Show the latest version and key changes."
        case "feedback":
            return "I want to submit feedback or report a bug. Help me write a clear bug report with session context."
        case "claude-api":
            return "Load the Claude API reference for the language used in \(workspace). Cover tool use, streaming, batches, structured outputs, and common pitfalls."
        case "powerup":
            return "Show me Claude Code features I might not know about — interactive lessons or tips."
        case "login":
            return "Help me sign in to my Anthropic account."
        case "logout":
            return "Sign me out from my Anthropic account."
        case "upgrade":
            return "Show me the available Claude plan tiers and help me upgrade."
        case "usage-credits":
            return "Help me configure usage credits so I can keep working when I hit a plan limit."

        // ── Connect commands ─────────────────────────────────────────────────
        case "ide":
            return "Show IDE integration status and help me configure VS Code or JetBrains."
        case "desktop":
            return "Open this session in the Claude Code Desktop app."
        case "remote-control":
            return "Make this session available for remote control from claude.ai."
        case "remote-env":
            return "Help me choose the default environment for cloud agents."
        case "teleport":
            return "Pull a Claude Code on the web session into this terminal."
        case "voice":
            return "Toggle voice dictation. Available modes: hold, tap, or off."
        case "chrome":
            return "Configure Claude in Chrome settings."
        case "terminal-setup":
            return "Configure terminal keybindings for this terminal (Shift+Enter and other shortcuts)."
        case "mobile":
            return "Show me how to download the Claude mobile app."
        case "setup-bedrock":
            return "Configure Amazon Bedrock authentication, region, and model pins for Claude Code."
        case "setup-vertex":
            return "Configure Google Vertex AI authentication, project, region, and model pins for Claude Code."

        default:
            return nil
        }
    }
}

// MARK: - AccountChip

private struct AccountChip: View {
    let account: ClaudeAccount
    let isActive: Bool
    let action: () -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        Button(action: action) {
            Text(account.name)
                .font(.system(size: appState.sf(11), weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.25),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - MessageRow

private struct MessageRow: View {
    let message: ClaudeMessage
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user { Spacer(minLength: 32) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                bubble
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            if message.role == .assistant { Spacer(minLength: 32) }
        }
    }

    @ViewBuilder
    private var bubble: some View {
        if message.role == .user {
            Text(message.content)
                .font(.system(size: appState.sf(13)))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if message.content.isEmpty && message.isStreaming {
                    ClaudeTypingIndicator()
                } else {
                    Text(message.content)
                        .font(.system(size: appState.sf(13)))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    if message.isStreaming {
                        ClaudeTypingIndicator()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.6),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }
}

// MARK: - ClaudeTypingIndicator

private struct ClaudeTypingIndicator: View {
    @State private var phase: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase == 0 ? 1.0 : (i == Int(phase * 2) % 3 ? 1.4 : 1.0))
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                               value: phase)
            }
        }
        .onAppear { phase = 1 }
    }
}
