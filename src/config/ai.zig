//! AI assistant configuration for Ghostty terminal.
//! This module provides Warp-like AI features including an agent input mode
//! and intelligent command suggestions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// AI provider options
pub const Provider = enum {
    /// OpenAI API
    openai,
    /// Anthropic Claude API
    anthropic,
    /// Local LLM via Ollama
    ollama,
    /// Custom OpenAI-compatible endpoint
    custom,

    pub fn parseCLI(input: ?[]const u8) !Provider {
        const str = input orelse return error.ValueRequired;
        if (str.len == 0) return error.ValueRequired;

        // Case-insensitive matching
        if (std.ascii.eqlIgnoreCase(str, "openai")) return .openai;
        if (std.ascii.eqlIgnoreCase(str, "anthropic")) return .anthropic;
        if (std.ascii.eqlIgnoreCase(str, "claude")) return .anthropic;
        if (std.ascii.eqlIgnoreCase(str, "ollama")) return .ollama;
        if (std.ascii.eqlIgnoreCase(str, "custom")) return .custom;

        return error.InvalidValue;
    }

    pub fn formatCLI(self: Provider) []const u8 {
        return switch (self) {
            .openai => "openai",
            .anthropic => "anthropic",
            .ollama => "ollama",
            .custom => "custom",
        };
    }
};

/// AI assistant configuration
pub const Assistant = struct {
    const Self = @This();

    /// Enable AI assistant features
    enabled: bool = false,

    /// AI provider to use
    provider: ?Provider = null,

    /// API key for the selected provider
    api_key: []const u8 = "",

    /// Custom endpoint URL (for custom provider)
    endpoint: []const u8 = "",

    /// Model to use (e.g., "gpt-4", "claude-3-opus")
    model: []const u8 = "",

    /// Maximum tokens for AI responses
    max_tokens: u32 = 1000,

    /// Temperature for AI responses (0.0 - 2.0)
    temperature: f32 = 0.7,

    /// Enable context awareness (reads terminal history)
    context_aware: bool = true,

    /// Number of lines of terminal history to include as context
    context_lines: u32 = 50,

    /// System prompt for the AI assistant
    system_prompt: []const u8 = defaultSystemPrompt(),

    /// Default prompt templates
    pub const PromptTemplate = struct {
        name: []const u8,
        template: []const u8,
        description: []const u8,
    };

    /// Built-in prompt templates
    pub const prompt_templates: []const PromptTemplate = &.{
        .{
            .name = "explain",
            .template = "Explain this command/output in simple terms:\n\n{selection}",
            .description = "Explain the selected command or output",
        },
        .{
            .name = "fix",
            .template = "What's wrong with this command and how do I fix it?\n\n{selection}",
            .description = "Identify and fix issues with the selected command",
        },
        .{
            .name = "optimize",
            .template = "Optimize this command for better performance:\n\n{selection}",
            .description = "Suggest performance optimizations",
        },
        .{
            .name = "rewrite",
            .template = "Rewrite this command using modern best practices:\n\n{selection}",
            .description = "Modernize the selected command",
        },
        .{
            .name = "document",
            .template = "Generate documentation for this command:\n\n{selection}",
            .description = "Create documentation for the command",
        },
        .{
            .name = "debug",
            .template = "Help debug this error:\n\n{selection}\n\nTerminal context:\n{context}",
            .description = "Debug errors with terminal context",
        },
        .{
            .name = "complete",
            .template = "Complete this command based on the pattern:\n\n{selection}",
            .description = "Auto-complete the command",
        },
        .{
            .name = "translate",
            .template = "Translate this error message to plain English:\n\n{selection}",
            .description = "Translate technical error messages",
        },
    };

    fn defaultSystemPrompt() []const u8 {
        return \\You are Ghostty AI, an intelligent terminal assistant. You help users with:
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
    }

    pub fn clone(self: *const Self, alloc: Allocator) !Self {
        return .{
            .enabled = self.enabled,
            .provider = self.provider,
            .api_key = try alloc.dupe(u8, self.api_key),
            .endpoint = try alloc.dupe(u8, self.endpoint),
            .model = try alloc.dupe(u8, self.model),
            .max_tokens = self.max_tokens,
            .temperature = self.temperature,
            .context_aware = self.context_aware,
            .context_lines = self.context_lines,
            .system_prompt = try alloc.dupe(u8, self.system_prompt),
        };
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        alloc.free(self.api_key);
        alloc.free(self.endpoint);
        alloc.free(self.model);
        alloc.free(self.system_prompt);
    }

    /// Format template with given selection and context
    pub fn formatTemplate(
        self: *const Self,
        alloc: Allocator,
        template: []const u8,
        selection: []const u8,
        context: ?[]const u8,
    ) ![]const u8 {
        _ = self;
        const context_str = context orelse "";
        var buf: std.Io.Writer.Allocating = .init(alloc);
        defer buf.deinit();

        var i: usize = 0;
        while (i < template.len) {
            if (i + 11 <= template.len and std.mem.eql(u8, template[i..i + 11], "{selection}")) {
                try buf.writer.writeAll(selection);
                i += 11; // Skip "{selection}"
            } else if (i + 9 <= template.len and std.mem.eql(u8, template[i..i + 9], "{context}")) {
                try buf.writer.writeAll(context_str);
                i += 9; // Skip "{context}"
            } else {
                try buf.writer.writeByte(template[i]);
                i += 1;
            }
        }

        return buf.toOwnedSlice();
    }

    /// Get prompt template by name
    pub fn getTemplate(name: []const u8) ?PromptTemplate {
        for (prompt_templates) |tpl| {
            if (std.mem.eql(u8, tpl.name, name)) {
                return tpl;
            }
        }
        return null;
    }
};

test "Provider.parseCLI" {
    const testing = std.testing;

    const openai = try Provider.parseCLI("OpenAI");
    try testing.expectEqual(Provider.openai, openai);

    const anthropic = try Provider.parseCLI("Claude");
    try testing.expectEqual(Provider.anthropic, anthropic);

    const ollama = try Provider.parseCLI("ollama");
    try testing.expectEqual(Provider.ollama, ollama);

    // Empty returns an error
    try testing.expectError(error.ValueRequired, Provider.parseCLI(""));
}

test "Assistant.formatTemplate" {
    const testing = std.testing;

    var assistant = Assistant{};
    const result = try assistant.formatTemplate(
        testing.allocator,
        "Test {selection} and {context}",
        "SELECTED",
        "CONTEXT",
    );
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("Test SELECTED and CONTEXT", result);
}

test "Assistant.getTemplate" {
    const testing = std.testing;

    const explain = Assistant.getTemplate("explain");
    try testing.expect(explain != null);
    try testing.expectEqualStrings("explain", explain.?.name);

    const invalid = Assistant.getTemplate("nonexistent");
    try testing.expectEqual(null, invalid);
}
