import SwiftUI
import Foundation

/// AI-Powered SSH Connection Assistant for macOS
/// Provides intelligent SSH connection suggestions, host completion, and command generation
struct SSHConnectionAssistant: View {
    @State private var hostInput: String = ""
    @State private var selectedHost: SSHHostEntry?
    @State private var knownHosts: [SSHHostEntry] = []
    @State private var recentConnections: [SSHConnectionHistory] = []
    @State private var generatedCommand: String = ""
    @State private var isLoading: Bool = false
    @State private var aiSuggestion: String = ""
    @State private var showCopied: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                Text("SSH Connection Assistant")
                    .font(.headline)

                Spacer()

                Button(action: refreshHosts) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Main content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Host input with autocomplete
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect to:")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)

                            TextField("Start typing a host...", text: $hostInput)
                                .textFieldStyle(.plain)
                                .onChange(of: hostInput) { newValue in
                                    filterHosts(matching: newValue)
                                }
                        }
                        .padding(10)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)

                        // Autocomplete suggestions
                        if !filteredHosts.isEmpty && !hostInput.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(filteredHosts.prefix(5), id: \.self) { host in
                                    Button(action: {
                                        selectHost(host)
                                    }) {
                                        HStack {
                                            Image(systemName: "server.rack")
                                                .foregroundColor(.secondary)
                                            Text(host.name)
                                                .foregroundColor(.primary)
                                            Spacer()
                                            if host.isRecent {
                                                Image(systemName: "clock")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                    }
                                    .buttonStyle(.plain)
                                    .background(Color(NSColor.selectedContentBackgroundColor).opacity(0.1))
                                    .cornerRadius(6)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal)

                    // Selected host details
                    if let host = selectedHost {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundColor(.accentColor)
                                Text(host.name)
                                    .font(.headline)
                                Spacer()
                                Button(action: {
                                    copyConnectionDetails(host)
                                }) {
                                    Label("Copy Details", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                            }

                            DetailRow(label: "Hostname", value: host.hostname)
                            if !host.user.isEmpty {
                                DetailRow(label: "User", value: host.user)
                            }
                            DetailRow(label: "Port", value: "\(host.port)")
                            if let identity = host.identityFile {
                                DetailRow(label: "Identity", value: identity)
                            }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .padding(.horizontal)
                    }

                    Divider()

                    // AI suggestion
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(.accentColor)
                            Text("AI Suggestion")
                                .font(.subheadline)
                                .fontWeight(.medium)
                        }

                        if isLoading {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Getting suggestion...")
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                        } else if !aiSuggestion.isEmpty {
                            Text(aiSuggestion)
                                .font(.system(.body, design: .monospaced))
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)

                            Button(action: {
                                copySuggestion()
                            }) {
                                HStack {
                                    if showCopied {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.green)
                                    } else {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    Text(showCopied ? "Copied!" : "Copy Suggestion")
                                }
                            }
                            .buttonStyle(.bordered)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    withAnimation {
                                        showCopied = false
                                    }
                                }
                            }
                        } else {
                            Text("Type a host or ask for AI suggestions")
                                .foregroundColor(.secondary)
                                .font(.caption)
                                .padding()
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // Quick connect buttons
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Quick Connect")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        HStack(spacing: 8) {
                            Button(action: {
                                generateQuickCommand(host: selectedHost?.name ?? hostInput, options: [])
                            }) {
                                Label("Basic SSH", systemImage: "terminal")
                            }
                            .buttonStyle(.bordered)

                            Button(action: {
                                generateQuickCommand(host: selectedHost?.name ?? hostInput, options: ["-A", "-C"])
                            }) {
                                Label("With Agent + Compression", systemImage: "key.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.horizontal)

                    Divider()

                    // Recent connections
                    if !recentConnections.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Connections")
                                .font(.subheadline)
                                .fontWeight(.medium)

                            ForEach(recentConnections.prefix(5), id: \.self) { conn in
                                Button(action: {
                                    selectRecentConnection(conn)
                                }) {
                                    HStack {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .foregroundColor(.secondary)
                                        Text(conn.host)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Text(formatDate(conn.timestamp))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
        }
        .frame(minWidth: 450, minHeight: 500)
        .onAppear {
            loadSSHConfig()
            loadHistory()
        }
    }

    // MARK: - Filtered Hosts

    @State private var filteredHosts: [SSHHostEntry] = []

    func filterHosts(matching input: String) {
        if input.isEmpty {
            filteredHosts = knownHosts
        } else {
            filteredHosts = knownHosts.filter {
                $0.name.localizedCaseInsensitiveContains(input) ||
                $0.hostname.localizedCaseInsensitiveContains(input)
            }
        }
    }

    // MARK: - Actions

    func selectHost(_ host: SSHHostEntry) {
        selectedHost = host
        hostInput = host.name
        filteredHosts = []
        generateQuickCommand(host: host.name, options: [])
        getAISuggestion(for: host.name)
    }

    func selectRecentConnection(_ conn: SSHConnectionHistory) {
        hostInput = conn.host
        if let knownHost = knownHosts.first(where: { $0.name == conn.host }) {
            selectedHost = knownHost
        }
        generateQuickCommand(host: conn.host, options: [])
    }

    func generateQuickCommand(host: String, options: [String]) {
        if let existingHost = knownHosts.first(where: { $0.name == host }) {
            var args = ["ssh"]
            if !existingHost.user.isEmpty {
                args.append("\(existingHost.user)@\(existingHost.hostname)")
            } else {
                args.append(existingHost.hostname)
            }
            if existingHost.port != 22 {
                args.append("-p \(existingHost.port)")
            }
            for opt in options {
                args.append(opt)
            }
            if let identity = existingHost.identityFile {
                args.append("-i \(identity)")
            }
            generatedCommand = args.joined(separator: " ")
        } else {
            var args = ["ssh", host]
            args.append(contentsOf: options)
            generatedCommand = args.joined(separator: " ")
        }
        aiSuggestion = generatedCommand
    }

    func getAISuggestion(for host: String) {
        isLoading = true
        // TODO: Call AI to get intelligent suggestions
        // For now, generate a contextual suggestion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let knownHost = knownHosts.first(where: { $0.name == host }) {
                aiSuggestion = "Try: ssh \(knownHost.user.isEmpty ? "" : "\(knownHost.user)@")\(knownHost.hostname) -p \(knownHost.port)"
                if let identity = knownHost.identityFile {
                    aiSuggestion += "\nWith key: ssh -i \(identity) \(knownHost.user.isEmpty ? "" : "\(knownHost.user)@")\(knownHost.hostname)"
                }
            } else {
                aiSuggestion = "Connecting to \(host)...\n\nTip: Add this host to ~/.ssh/config for easier connections in the future."
            }
            isLoading = false
        }
    }

    func copySuggestion() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(aiSuggestion, forType: .string)
        #endif
        showCopied = true
    }

    func copyConnectionDetails(_ host: SSHHostEntry) {
        #if os(macOS)
        let details = """
        Host: \(host.name)
        Hostname: \(host.hostname)
        User: \(host.user)
        Port: \(host.port)
        Identity: \(host.identityFile ?? "default")
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(details, forType: .string)
        #endif
    }

    func refreshHosts() {
        loadSSHConfig()
    }

    // MARK: - Data Loading

    func loadSSHConfig() {
        // Load from ~/.ssh/config
        guard let home = FileManager.default.homeDirectoryForCurrentUser.path as String? else { return }
        let configPath = "\(home)/.ssh/config"

        var hosts: [SSHHostEntry] = []
        var currentHost: SSHHostEntry?

        do {
            let content = try String(contentsOfFile: configPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

                if let range = trimmed.range(of: "^Host\\s+", options: .regularExpression) {
                    if let host = currentHost {
                        hosts.append(host)
                    }
                    let hostName = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    currentHost = SSHHostEntry(
                        name: hostName,
                        hostname: hostName,
                        user: "",
                        port: 22,
                        identityFile: nil,
                        isRecent: false
                    )
                } else if var host = currentHost {
                    if let range = trimmed.range(of: "^Hostname\\s+", options: .regularExpression) {
                        host.hostname = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        currentHost = host
                    } else if let range = trimmed.range(of: "^User\\s+", options: .regularExpression) {
                        host.user = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        currentHost = host
                    } else if let range = trimmed.range(of: "^Port\\s+", options: .regularExpression) {
                        host.port = UInt16(String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)) ?? 22
                        currentHost = host
                    } else if let range = trimmed.range(of: "^IdentityFile\\s+", options: .regularExpression) {
                        host.identityFile = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                        currentHost = host
                    }
                }
            }

            if let host = currentHost {
                hosts.append(host)
            }
        } catch {
            // File doesn't exist or can't be read - that's okay
        }

        // Mark recent ones
        for conn in recentConnections {
            if let idx = hosts.firstIndex(where: { $0.name == conn.host }) {
                hosts[idx].isRecent = true
            }
        }

        knownHosts = hosts
        filteredHosts = hosts
    }

    func loadHistory() {
        // Load from XDG_STATE_HOME/ghostty/ssh_history
        let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"] ?? "\(NSHomeDirectory())/.local/state"
        let historyPath = "\(stateHome)/ghostty/ssh_history"

        var history: [SSHConnectionHistory] = []

        do {
            let content = try String(contentsOfFile: historyPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)

            for line in lines {
                let parts = line.components(separatedBy: "\t")
                if parts.count >= 3 {
                    history.append(SSHConnectionHistory(
                        host: parts[0],
                        timestamp: Int64(parts[1]) ?? 0,
                        command: parts[2]
                    ))
                }
            }
        } catch {
            // File doesn't exist
        }

        // Sort by timestamp, most recent first
        recentConnections = history.sorted { $0.timestamp > $1.timestamp }
    }

    func formatDate(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Supporting Types

struct SSHHostEntry: Hashable {
    let name: String
    var hostname: String
    var user: String
    var port: UInt16
    var identityFile: String?
    var isRecent: Bool = false
}

struct SSHConnectionHistory: Hashable {
    let host: String
    let timestamp: Int64
    let command: String
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Preview

#Preview {
    SSHConnectionAssistant()
}
