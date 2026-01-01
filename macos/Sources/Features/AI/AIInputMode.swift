import SwiftUI
import Foundation
import GhosttyKit
import Speech

/// AI Input Mode View for macOS
/// Provides a Warp-like AI assistant interface for command explanation,
/// error debugging, workflow optimization, and more.
struct AIInputModeView: View {
    @EnvironmentObject private var ghostty: Ghostty.App
    let surfaceView: Ghostty.SurfaceView?
    @State private var userInput: String = ""
    @State private var selectedTemplate: String = "Custom Question"
    @State private var responses: [AIResponse] = []
    @State private var isLoading: Bool = false
    @State private var selectedText: String?
    @State private var terminalContext: String?
    @State private var agentModeEnabled: Bool = false
    @StateObject private var voiceInput = VoiceInputManager()

    let templates = [
        "Custom Question",
        "Explain",
        "Fix",
        "Optimize",
        "Rewrite",
        "Debug",
        "Complete"
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Template selection
            HStack {
                Text("Template:")
                    .foregroundColor(.secondary)
                Picker("Template", selection: $selectedTemplate) {
                    ForEach(templates, id: \.self) { template in
                        Text(template).tag(template)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Agent Mode", isOn: $agentModeEnabled)
                    .toggleStyle(.switch)
                    .help("⚠️ Agent mode: automatically executes shell commands from AI responses WITHOUT confirmation. Use with caution - only enable for trusted AI providers!")
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top)
            .padding(.bottom, 8)

            // Input area
            HStack(spacing: 8) {
                TextField("Ask AI...", text: $userInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(NSColor.textBackgroundColor))
                    )

                // Voice input button
                Button(action: {
                    // Check authorization before allowing voice input
                    if voiceInput.authorizationStatus == .notDetermined {
                        voiceInput.requestAuthorization()
                    } else if voiceInput.authorizationStatus == .authorized {
                        voiceInput.toggleListening()
                    }
                    // If denied/restricted, button appears to do nothing - errorMessage will show the issue
                }) {
                    Image(systemName: voiceInput.isListening ? "mic.fill" : "mic")
                        .foregroundColor(voiceInput.isListening ? .red : .secondary)
                }
                .disabled(voiceInput.authorizationStatus == .denied || voiceInput.authorizationStatus == .restricted)
                .buttonStyle(.plain)
                .help(voiceInput.isListening ? "Stop listening" : "Voice input")

                Button(action: sendRequest) {
                    Image(systemName: "paperplane.fill")
                }
                .disabled(userInput.isEmpty || isLoading)
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .onChange(of: voiceInput.transcribedText) { newValue in
                // Only replace if input is empty or contains voice text
                // This prevents voice from accidentally overwriting user's typed input
                if !newValue.isEmpty {
                    if userInput.isEmpty {
                        userInput = newValue
                    }
                    // If user has manually edited, we don't overwrite
                }
            }

            Divider()

            // Context indicator
            if selectedText != nil {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("AI will use selected text as context")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            // Voice input status
            if voiceInput.isListening {
                HStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Listening... speak now")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            // Voice input error
            if let errorMessage = voiceInput.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(errorMessage)
                }
                .font(.caption)
                .foregroundColor(.red)
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            // Responses area
            if responses.isEmpty && !isLoading {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Ask me anything about commands, errors, or workflows")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(responses) { response in
                                AIResponseView(response: response)
                                    .id(response.id)
                            }

                            if isLoading {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Thinking...")
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                            }
                        }
                        .padding()
                    }
                    .onChange(of: responses.count) { _ in
                        if let lastResponse = responses.last {
                            withAnimation {
                                proxy.scrollTo(lastResponse.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private func sendRequest() {
        guard !userInput.isEmpty else { return }

        isLoading = true
        let input = userInput
        userInput = ""

        // Build the prompt based on template
        let prompt = buildPrompt(input: input, template: selectedTemplate)
        let finalPrompt = agentModeEnabled
            ? prompt + "\n\nIf you provide commands, wrap them in fenced code blocks and put one command per line."
            : prompt

        // Create a placeholder response for streaming
        let placeholderResponse = AIResponse(
            content: "",
            isUser: false,
            isStreaming: true
        )
        responses.append(placeholderResponse)

        // Send request to AI backend via C bridge
        let appHandle = ghostty.app
        DispatchQueue.global(qos: .userInitiated).async {
            // Get the app instance
            guard let app = appHandle else {
                DispatchQueue.main.async {
                    self.updateResponseWithError("App not available")
                }
                return
            }

            // Create AI instance
            guard let ai = ghostty_ai_new(app) else {
                DispatchQueue.main.async {
                    self.updateResponseWithError("AI not configured")
                }
                return
            }
            defer { ghostty_ai_free(ai) }

            // Check if AI is ready
            guard ghostty_ai_is_ready(ai) else {
                DispatchQueue.main.async {
                    self.updateResponseWithError("AI is not properly configured. Check ai-enabled, ai-provider, and ai-api-key settings.")
                }
                return
            }

            // Convert prompt to C string
            let promptData = finalPrompt.data(using: .utf8) ?? Data()
            let contextData = (self.terminalContext ?? "").data(using: .utf8) ?? Data()

            // Make the AI request
            let response = promptData.withUnsafeBytes { promptPtr -> ghostty_ai_response_s in
                let promptCPtr = promptPtr.baseAddress?.assumingMemoryBound(to: CChar.self)
                return contextData.withUnsafeBytes { contextPtr -> ghostty_ai_response_s in
                    let contextCPtr = contextData.isEmpty ? nil : contextPtr.baseAddress?.assumingMemoryBound(to: CChar.self)
                    return ghostty_ai_chat(
                        ai,
                        promptCPtr,
                        UInt(promptData.count),
                        contextCPtr,
                        UInt(contextData.count)
                    )
                }
            }

            // Process response on main thread
            DispatchQueue.main.async {
                if response.success {
                    let content = response.content.map { String(cString: $0) } ?? ""
                    let aiResponse = AIResponse(
                        content: content,
                        isUser: false,
                        isStreaming: false
                    )
                    self.responses.removeLast()
                    self.responses.append(aiResponse)
                    if self.agentModeEnabled {
                        self.executeCommands(from: content)
                    }
                } else {
                    let errorMsg = response.error_message.map { String(cString: $0) } ?? "Unknown error"
                    self.updateResponseWithError(errorMsg)
                }
                self.isLoading = false

                // Free the response
                var mutableResponse = response
                ghostty_ai_response_free(ai, &mutableResponse)
            }
        }
    }

    private func updateResponseWithError(_ message: String) {
        let errorResponse = AIResponse(
            content: "Error: \(message)",
            isUser: false,
            isStreaming: false
        )
        responses.removeLast()
        responses.append(errorResponse)
        isLoading = false
    }

    private func executeCommands(from response: String) {
        let commands = extractCommands(from: response)
        guard !commands.isEmpty else { return }
        guard let surfaceView else { return }

        Task { @MainActor in
            guard let surface = surfaceView.surfaceModel else { return }
            for command in commands {
                surface.sendText(command + "\n")
            }
        }
    }

    private func extractCommands(from response: String) -> [String] {
        var commands: [String] = []

        let lines = response.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                i += 1
                if i < lines.count && !lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    i += 1
                }
                while i < lines.count && !lines[i].hasPrefix("```") {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                        commands.append(trimmed)
                    }
                    i += 1
                }
            }
            i += 1
        }

        if !commands.isEmpty {
            return commands
        }

        var buffer = ""
        var inInline = false
        for char in response {
            if char == "`" {
                if inInline {
                    let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        commands.append(trimmed)
                    }
                    buffer = ""
                }
                inInline.toggle()
                continue
            }
            if inInline {
                buffer.append(char)
            }
        }

        return commands
    }

    private func buildPrompt(input: String, template: String) -> String {
        switch template {
        case "Custom Question":
            return input
        case "Explain":
            return "Explain this command/output in simple terms:\n\n\(selectedText ?? input)"
        case "Fix":
            return "What's wrong with this command and how do I fix it?\n\n\(selectedText ?? input)"
        case "Optimize":
            return "Optimize this command for better performance:\n\n\(selectedText ?? input)"
        case "Rewrite":
            return "Rewrite this command using modern best practices:\n\n\(selectedText ?? input)"
        case "Debug":
            return "Help debug this error:\n\n\(selectedText ?? input)\n\nTerminal context:\n\(terminalContext ?? "N/A")"
        case "Complete":
            return "Complete this command based on the pattern:\n\n\(selectedText ?? input)"
        default:
            return input
        }
    }
}

/// Represents an AI response
struct AIResponse: Identifiable, Equatable {
    let id = UUID()
    let content: String
    let isUser: Bool
    let isStreaming: Bool

    static func == (lhs: AIResponse, rhs: AIResponse) -> Bool {
        lhs.id == rhs.id
    }
}

/// View for displaying an AI response with markdown-like formatting
struct AIResponseView: View {
    let response: AIResponse
    @State private var showCopied: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if response.isUser {
                // User input
                HStack {
                    Text(response.content)
                        .padding(8)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(8)
                    Spacer()
                }
            } else {
                // AI response
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.accentColor)
                        .font(.caption)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(response.content)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    // Copy button
                    Button(action: copyToClipboard) {
                        if showCopied {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Copy to clipboard")
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
        }
    }

    private func copyToClipboard() {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(response.content, forType: .string)
        #endif

        // Show feedback
        withAnimation {
            showCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopied = false
            }
        }
    }
}

/// Window wrapper for AI Input Mode
struct AIInputModeWindow: View {
    @State private var isPresented: Bool = false
    let selectedText: String?
    let terminalContext: String?

    init(selectedText: String? = nil, terminalContext: String? = nil) {
        self.selectedText = selectedText
        self.terminalContext = terminalContext
    }

    var body: some View {
        AIInputModeView(surfaceView: nil)
            .environment(\.selectedText, selectedText ?? "")
            .environment(\.terminalContext, terminalContext ?? "")
    }
}

/// Environment keys for AI Input Mode
private struct SelectedTextKey: EnvironmentKey {
    static let defaultValue: String = ""
}

private struct TerminalContextKey: EnvironmentKey {
    static let defaultValue: String = ""
}

extension EnvironmentValues {
    var selectedText: String {
        get { self[SelectedTextKey.self] }
        set { self[SelectedTextKey.self] = newValue }
    }

    var terminalContext: String {
        get { self[TerminalContextKey.self] }
        set { self[TerminalContextKey.self] = newValue }
    }
}

// MARK: - Preview

#Preview {
    AIInputModeView(surfaceView: nil)
}
