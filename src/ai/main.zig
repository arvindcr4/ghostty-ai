//! AI Module for Ghostty Terminal
//!
//! This module provides Warp-like AI features for Ghostty, including
//! intelligent command assistance, error debugging, workflow optimization,
//! and more.

const std = @import("std");
const Allocator = std.mem.Allocator;

const client_module = @import("client.zig");
pub const Client = client_module.Client;
pub const ChatResponse = client_module.ChatResponse;
pub const Provider = client_module.Provider;
pub const SshAssistant = @import("ssh.zig").SshAssistant;
pub const SshHost = @import("ssh.zig").SshHost;
pub const ExplanationService = @import("explanation.zig").ExplanationService;
pub const ThemeAssistant = @import("theme.zig").ThemeAssistant;
pub const Theme = @import("theme.zig").Theme;
pub const ThemeSuggestion = @import("theme.zig").ThemeSuggestion;
pub const ThemeCategory = @import("theme.zig").ThemeCategory;
pub const SuggestionContext = @import("theme.zig").SuggestionContext;
pub const TimeOfDay = @import("theme.zig").TimeOfDay;
pub const Activity = @import("theme.zig").Activity;
pub const Preferences = @import("theme.zig").Preferences;
pub const Redactor = @import("redactor.zig").Redactor;
pub const SuggestionService = @import("suggestions.zig").SuggestionService;
pub const Suggestion = @import("suggestions.zig").Suggestion;
pub const PromptSuggestionService = @import("prompt_suggestions.zig").PromptSuggestionService;
pub const PromptSuggestion = @import("prompt_suggestions.zig").PromptSuggestion;
pub const CompletionsService = @import("completions.zig").CompletionsService;
pub const Completion = @import("completions.zig").Completion;
pub const ActiveAI = @import("active.zig").ActiveAI;
pub const Recommendation = @import("active.zig").Recommendation;
pub const TerminalState = @import("active.zig").TerminalState;

/// AI Assistant - Main interface for AI features
pub const Assistant = struct {
    const Self = @This();

    alloc: Allocator,
    client: Client,
    config: Config,
    redactor: ?*Redactor,

    pub const Config = struct {
        enabled: bool = false,
        provider: ?Provider = null,
        api_key: []const u8 = "",
        endpoint: []const u8 = "",
        model: []const u8 = "",
        max_tokens: u32 = 1000,
        temperature: f32 = 0.7,
        context_aware: bool = true,
        context_lines: u32 = 50,
        system_prompt: []const u8 = defaultSystemPrompt,
        redact_secrets: bool = true,
    };

    /// Default system prompt optimized for terminal assistance
    const defaultSystemPrompt =
        \\You are Ghostty AI, an intelligent terminal assistant. You help users with:
        \\- Explaining commands and their outputs
        \\- Debugging errors and suggesting fixes
        \\- Optimizing terminal workflows
        \\- Writing and improving shell scripts
        \\- Answering questions about terminal usage
        \\
        \\Be concise, practical, and provide working examples when relevant.
        \\When showing code, use proper formatting and keep it copy-paste ready.
        \\If you're unsure, ask clarifying questions rather than making assumptions.
    ;

    /// Create a new AI assistant
    pub fn init(alloc: Allocator, config: Config) !Self {
        const provider = config.provider orelse return error.NoProvider;
        const api_key = config.api_key;
        const endpoint = config.endpoint;
        const model = config.model;

        if (model.len == 0) return error.NoModel;

        const client = Client.init(
            alloc,
            provider,
            api_key,
            endpoint,
            model,
            config.max_tokens,
            config.temperature,
        );

        // Initialize redactor if secret redaction is enabled
        var redactor: ?*Redactor = null;
        if (config.redact_secrets) {
            const r = try alloc.create(Redactor);
            r.* = Redactor.init(alloc);
            redactor = r;
        }

        return .{
            .alloc = alloc,
            .client = client,
            .config = config,
            .redactor = redactor,
        };
    }

    /// Clean up assistant resources
    pub fn deinit(self: *Self) void {
        if (self.redactor) |r| {
            r.deinit();
            self.alloc.destroy(r);
        }
    }

    /// Process a user prompt with optional context
    pub fn process(
        self: *Self,
        prompt: []const u8,
        context: ?[]const u8,
    ) !ChatResponse {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();

        // Redact sensitive information from prompt if enabled
        const redacted_prompt = if (self.config.redact_secrets and self.redactor != null)
            try self.redactor.?.redact(prompt)
        else
            prompt;
        defer if (self.config.redact_secrets and self.redactor != null)
            self.alloc.free(redacted_prompt);

        try buf.appendSlice(redacted_prompt);

        if (context) |ctx| {
            try buf.appendSlice("\n\nContext:\n");

            // Redact sensitive information from context if enabled
            const redacted_context = if (self.config.redact_secrets and self.redactor != null)
                try self.redactor.?.redact(ctx)
            else
                ctx;
            defer if (self.config.redact_secrets and self.redactor != null)
                self.alloc.free(redacted_context);

            try buf.appendSlice(redacted_context);
        }

        const full_prompt = try buf.toOwnedSlice();
        defer self.alloc.free(full_prompt);

        return self.client.chat(self.config.system_prompt, full_prompt);
    }

    /// Streaming process callback type
    pub const StreamCallback = Client.StreamCallback;

    /// Streaming process options
    pub const StreamOptions = Client.StreamOptions;

    /// Process a user prompt with optional context using streaming
    /// The callback will be invoked for each chunk of the response
    pub fn processStream(
        self: *Self,
        prompt: []const u8,
        context: ?[]const u8,
        options: StreamOptions,
    ) !void {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();

        // Redact sensitive information from prompt if enabled
        const redacted_prompt = if (self.config.redact_secrets and self.redactor != null)
            try self.redactor.?.redact(prompt)
        else
            prompt;
        defer if (self.config.redact_secrets and self.redactor != null)
            self.alloc.free(redacted_prompt);

        try buf.appendSlice(redacted_prompt);

        if (context) |ctx| {
            try buf.appendSlice("\n\nContext:\n");

            // Redact sensitive information from context if enabled
            const redacted_context = if (self.config.redact_secrets and self.redactor != null)
                try self.redactor.?.redact(ctx)
            else
                ctx;
            defer if (self.config.redact_secrets and self.redactor != null)
                self.alloc.free(redacted_context);

            try buf.appendSlice(redacted_context);
        }

        const full_prompt = try buf.toOwnedSlice();
        defer self.alloc.free(full_prompt);

        return self.client.chatStream(self.config.system_prompt, full_prompt, options);
    }

    /// Check if AI is properly configured and ready
    pub fn isReady(self: *const Self) bool {
        return self.config.enabled and
            self.config.provider != null and
            self.config.model.len > 0 and
            (self.config.api_key.len > 0 or self.config.provider == .ollama);
    }
};

// ============================================================================
// Unit Test Imports
// ============================================================================
// Import all AI module files to include their inline tests in the build

test {
    // Core AI modules
    _ = @import("validation.zig");
    _ = @import("client.zig");
    _ = @import("redactor.zig");

    // Feature modules
    _ = @import("active.zig");
    _ = @import("analytics.zig");
    _ = @import("blocks.zig");
    _ = @import("collaboration.zig");
    _ = @import("command_corrections.zig");
    _ = @import("command_history.zig");
    _ = @import("completions.zig");
    _ = @import("corrections.zig");
    _ = @import("custom_prompts.zig");
    _ = @import("documentation.zig");
    _ = @import("embeddings.zig");
    _ = @import("error_recovery.zig");
    _ = @import("explanation.zig");
    _ = @import("export_import.zig");
    _ = @import("history.zig");
    _ = @import("ide_editing.zig");
    _ = @import("keyboard_shortcuts.zig");
    _ = @import("knowledge_rules.zig");
    _ = @import("mcp.zig");
    _ = @import("multi_turn.zig");
    _ = @import("next_command.zig");
    _ = @import("notebooks.zig");
    _ = @import("notifications.zig");
    _ = @import("performance.zig");
    _ = @import("plugins.zig");
    _ = @import("progress.zig");
    _ = @import("prompt_suggestions.zig");
    _ = @import("rich_history.zig");
    _ = @import("rollback.zig");
    _ = @import("secrets.zig");
    _ = @import("security.zig");
    _ = @import("session_sharing.zig");
    _ = @import("sharing.zig");
    _ = @import("shell.zig");
    _ = @import("ssh.zig");
    _ = @import("suggestions.zig");
    _ = @import("theme.zig");
    _ = @import("theme_suggestions.zig");
    _ = @import("voice.zig");
    _ = @import("workflow.zig");
    _ = @import("workflows.zig");
}
