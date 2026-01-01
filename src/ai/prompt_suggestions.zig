//! AI Prompt Suggestions Module
//!
//! This module provides contextual AI-powered suggestions while typing
//! in the AI input mode. It analyzes partial input and offers relevant
//! prompt completions and quick actions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const ComptimeStringMap = std.ComptimeStringMap;

const log = std.log.scoped(.ai_prompt_suggestions);

/// A suggested prompt completion
pub const PromptSuggestion = struct {
    /// Suggested text to insert
    completion: []const u8,
    /// Description of what this suggestion does
    description: []const u8,
    /// Type of suggestion
    kind: Kind,
    /// Confidence score (0.0-1.0)
    confidence: f32,

    pub const Kind = enum {
        /// Template-based suggestion
        template,
        /// Auto-completion from common patterns
        autocomplete,
        /// Context-aware suggestion
        contextual,
        /// Quick action
        quick_action,
    };

    pub fn deinit(self: *const PromptSuggestion, alloc: Allocator) void {
        alloc.free(self.completion);
        alloc.free(self.description);
    }
};

/// Pattern-based prompt completions
const PromptPattern = struct {
    trigger: []const u8,
    completion: []const u8,
    description: []const u8,
};

/// Common trigger patterns and their completions
const trigger_patterns = [_]PromptPattern{
    .{
        .trigger = "how do i",
        .completion = "How do I ",
        .description = "Ask how to do something",
    },
    .{
        .trigger = "explain",
        .completion = "Explain this ",
        .description = "Get an explanation",
    },
    .{
        .trigger = "what is",
        .completion = "What is ",
        .description = "Ask what something is",
    },
    .{
        .trigger = "why is",
        .completion = "Why is ",
        .description = "Ask why something is happening",
    },
    .{
        .trigger = "debug",
        .completion = "Help debug this error:\n\n",
        .description = "Debug an error",
    },
    .{
        .trigger = "fix",
        .completion = "Fix this command:\n\n",
        .description = "Fix a broken command",
    },
    .{
        .trigger = "optimize",
        .completion = "Optimize this for better performance:\n\n",
        .description = "Optimize something",
    },
    .{
        .trigger = "rewrite",
        .completion = "Rewrite this using modern best practices:\n\n",
        .description = "Modernize code/command",
    },
    .{
        .trigger = "convert",
        .completion = "Convert this to ",
        .description = "Convert between formats",
    },
    .{
        .trigger = "compare",
        .completion = "Compare the differences between:\n\n1. \n2. ",
        .description = "Compare two things",
    },
    .{
        .trigger = "generate",
        .completion = "Generate a ",
        .description = "Generate something new",
    },
    .{
        .trigger = "summarize",
        .completion = "Summarize the following:\n\n",
        .description = "Summarize content",
    },
    .{
        .trigger = "which",
        .completion = "Which tool/command should I use to ",
        .description = "Get tool recommendations",
    },
};

/// Contextual suggestions based on selection type
const ContextualSuggestion = struct {
    keywords: []const []const u8,
    suggestion: []const u8,
    description: []const u8,
};

const contextual_patterns = [_]ContextualSuggestion{
    .{
        .keywords = &[_][]const u8{ "error", "failed", "exception", "cannot" },
        .suggestion = "What's wrong with this and how do I fix it?",
        .description = "Debug error",
    },
    .{
        .keywords = &[_][]const u8{ "slow", "lag", "performance", "taking too long" },
        .suggestion = "How can I optimize this for better performance?",
        .description = "Optimize performance",
    },
    .{
        .keywords = &[_][]const u8{ "git", "commit", "push", "pull", "merge" },
        .suggestion = "Suggest the best git workflow for this scenario",
        .description = "Git workflow advice",
    },
    .{
        .keywords = &[_][]const u8{ "docker", "container", "image", "build" },
        .suggestion = "Help me write an efficient Docker setup",
        .description = "Docker assistance",
    },
    .{
        .keywords = &[_][]const u8{ "ssh", "connect", "remote", "server" },
        .suggestion = "Help me set up SSH connection properly",
        .description = "SSH assistance",
    },
    .{
        .keywords = &[_][]const u8{ "permission", "denied", "access", "sudo" },
        .suggestion = "Explain the permission issue and how to resolve it",
        .description = "Permission help",
    },
    .{
        .keywords = &[_][]const u8{ "install", "setup", "configure" },
        .suggestion = "Guide me through the installation step by step",
        .description = "Installation guide",
    },
    .{
        .keywords = &[_][]const u8{ "json", "yaml", "csv", "parse" },
        .suggestion = "Help me parse and work with this data format",
        .description = "Data parsing",
    },
};

/// Quick action suggestions
const QuickAction = struct {
    name: []const u8,
    template: []const u8,
    description: []const u8,
};

const quick_actions = [_]QuickAction{
    .{
        .name = "explain_selection",
        .template = "Explain this in simple terms:\n\n{selection}",
        .description = "Explain selected text",
    },
    .{
        .name = "fix_command",
        .template = "What's wrong with this command and how do I fix it?\n\n{selection}",
        .description = "Fix selected command",
    },
    .{
        .name = "optimize",
        .template = "Optimize this for better performance:\n\n{selection}",
        .description = "Optimize selection",
    },
    .{
        .name = "rewrite_modern",
        .template = "Rewrite this using modern best practices:\n\n{selection}",
        .description = "Modernize code",
    },
    .{
        .name = "add_documentation",
        .template = "Add comprehensive documentation for:\n\n{selection}",
        .description = "Add docs",
    },
    .{
        .name = "find_alternative",
        .template = "Suggest alternative approaches to:\n\n{selection}",
        .description = "Find alternatives",
    },
    .{
        .name = "security_review",
        .template = "Review this for security issues:\n\n{selection}",
        .description = "Security review",
    },
    .{
        .name = "convert_to_script",
        .template = "Convert this to a reusable shell script:\n\n{selection}",
        .description = "Convert to script",
    },
    .{
        .name = "explain_error",
        .template = "Explain this error and how to fix it:\n\n{selection}\n\nContext:\n{context}",
        .description = "Debug error with context",
    },
    .{
        .name = "suggest_next",
        .template = "What should I do next after:\n\n{selection}",
        .description = "Suggest next steps",
    },
};

/// Prompt Suggestion Service
pub const PromptSuggestionService = struct {
    alloc: Allocator,
    enabled: bool,
    max_suggestions: usize,

    /// Initialize the prompt suggestion service
    pub fn init(alloc: Allocator, max_suggestions: usize) PromptSuggestionService {
        return .{
            .alloc = alloc,
            .enabled = true,
            .max_suggestions = max_suggestions,
        };
    }

    /// Get suggestions based on partial input
    pub fn getSuggestions(
        self: *const PromptSuggestionService,
        partial_input: []const u8,
        selected_text: ?[]const u8,
        terminal_context: ?[]const u8,
    ) !std.ArrayList(PromptSuggestion) {
        var suggestions = std.ArrayList(PromptSuggestion).init(self.alloc);
        errdefer {
            for (suggestions.items) |*s| s.deinit(self.alloc);
            suggestions.deinit();
        }

        if (!self.enabled) return suggestions;

        const lower_input = try self.toLower(partial_input);
        defer self.alloc.free(lower_input);

        // 1. Trigger-based autocomplete suggestions
        try self.addTriggerSuggestions(&suggestions, partial_input, lower_input);

        // 2. Contextual suggestions based on selection
        if (selected_text != null and selected_text.?.len > 0) {
            try self.addContextualSuggestions(&suggestions, selected_text.?);
        }

        // 3. Quick action suggestions (only if input is empty or very short)
        if (partial_input.len < 10) {
            try self.addQuickActionSuggestions(&suggestions, selected_text != null);
        }

        // 4. Terminal context suggestions
        if (terminal_context != null and terminal_context.?.len > 0) {
            try self.addContextBasedSuggestions(&suggestions, terminal_context.?);
        }

        // Sort by confidence and limit
        std.sort.insertion(PromptSuggestion, suggestions.items, {}, struct {
            fn compare(_: void, a: PromptSuggestion, b: PromptSuggestion) bool {
                return a.confidence > b.confidence;
            }
        }.compare);

        // Trim to max suggestions
        while (suggestions.items.len > self.max_suggestions) {
            const removed = suggestions.pop();
            removed.deinit(self.alloc);
        }

        return suggestions;
    }

    /// Add trigger-based autocomplete suggestions
    fn addTriggerSuggestions(
        self: *const PromptSuggestionService,
        suggestions: *std.ArrayList(PromptSuggestion),
        partial_input: []const u8,
        lower_input: []const u8,
    ) !void {
        for (trigger_patterns) |pattern| {
            // Check if the pattern trigger is a prefix of input
            if (std.mem.indexOf(u8, lower_input, pattern.trigger)) |idx| {
                if (idx == 0 or (idx > 0 and partial_input[idx - 1] == ' ')) {
                    // Only suggest if we're not past the trigger
                    const suggestion = PromptSuggestion{
                        .completion = try self.alloc.dupe(u8, pattern.completion),
                        .description = try self.alloc.dupe(u8, pattern.description),
                        .kind = .autocomplete,
                        .confidence = 0.9,
                    };
                    try suggestions.append(suggestion);
                }
            }
        }
    }

    /// Add contextual suggestions based on selected text
    fn addContextualSuggestions(
        self: *const PromptSuggestionService,
        suggestions: *std.ArrayList(PromptSuggestion),
        selected_text: []const u8,
    ) !void {
        const lower_selection = try self.toLower(selected_text);
        defer self.alloc.free(lower_selection);

        for (contextual_patterns) |pattern| {
            for (pattern.keywords) |keyword| {
                if (std.mem.indexOf(u8, lower_selection, keyword)) |_| {
                    const suggestion = PromptSuggestion{
                        .completion = try self.alloc.dupe(u8, pattern.suggestion),
                        .description = try self.alloc.dupe(u8, pattern.description),
                        .kind = .contextual,
                        .confidence = 0.85,
                    };
                    try suggestions.append(suggestion);
                    break;
                }
            }
        }
    }

    /// Add quick action suggestions
    fn addQuickActionSuggestions(
        self: *const PromptSuggestionService,
        suggestions: *std.ArrayList(PromptSuggestion),
        has_selection: bool,
    ) !void {
        for (quick_actions) |action| {
            // Only show selection-based actions if we have a selection
            if (std.mem.indexOf(u8, action.template, "{selection}") != null and !has_selection) {
                continue;
            }

            const suggestion = PromptSuggestion{
                .completion = try self.alloc.dupe(u8, action.template),
                .description = try self.alloc.dupe(u8, action.description),
                .kind = .quick_action,
                .confidence = 0.75,
            };
            try suggestions.append(suggestion);
        }
    }

    /// Add suggestions based on terminal context
    fn addContextBasedSuggestions(
        self: *const PromptSuggestionService,
        suggestions: *std.ArrayList(PromptSuggestion),
        context: []const u8,
    ) !void {
        const lower_context = try self.toLower(context);
        defer self.alloc.free(lower_context);

        // Check for error patterns in context
        const error_keywords = [_][]const u8{ "error", "failed", "exception", "cannot", "denied" };
        for (error_keywords) |keyword| {
            if (std.mem.indexOf(u8, lower_context, keyword)) |_| {
                const suggestion = PromptSuggestion{
                    .completion = try self.alloc.dupe(u8, "Help debug this error based on the terminal context"),
                    .description = try self.alloc.dupe(u8, "Debug terminal error"),
                    .kind = .contextual,
                    .confidence = 0.8,
                };
                try suggestions.append(suggestion);
                break;
            }
        }

        // Check for git-related context
        if (std.mem.indexOf(u8, lower_context, "git") != null) {
            const suggestion = PromptSuggestion{
                .completion = try self.alloc.dupe(u8, "Suggest the next git command I should run"),
                .description = try self.alloc.dupe(u8, "Next git command"),
                .kind = .contextual,
                .confidence = 0.7,
            };
            try suggestions.append(suggestion);
        }
    }

    /// Get suggestion for completing a partial template
    pub fn completeTemplate(
        self: *const PromptSuggestionService,
        partial_input: []const u8,
    ) !?[]const u8 {
        // Check if the input looks like it wants a template
        if (partial_input.len < 3) return null;

        const lower = try self.toLower(partial_input);
        defer self.alloc.free(lower);

        // Map keywords to templates
        const template_map = [_]struct {
            keyword: []const u8,
            template: []const u8,
        }{
            .{ .keyword = "explain", .template = "Explain {selection} in simple terms" },
            .{ .keyword = "fix", .template = "What's wrong and how to fix: {selection}" },
            .{ .keyword = "opt", .template = "Optimize for performance: {selection}" },
            .{ .keyword = "rewrite", .template = "Rewrite using best practices: {selection}" },
            .{ .keyword = "debug", .template = "Debug error: {selection}\n\nContext:\n{context}" },
        };

        for (template_map) |entry| {
            if (std.mem.indexOf(u8, lower, entry.keyword)) |_| {
                return self.alloc.dupe(u8, entry.template);
            }
        }

        return null;
    }

    /// Check if a suggestion should be shown based on input
    pub fn shouldShowSuggestion(
        self: *const PromptSuggestionService,
        input: []const u8,
        min_length: usize,
    ) bool {
        if (!self.enabled) return false;
        if (input.len < min_length) return false;

        // Don't show suggestions if user is just typing spaces
        const trimmed = std.mem.trimLeft(u8, input, " ");
        return trimmed.len > 0;
    }

    /// Convert string to lowercase (helper)
    fn toLower(self: *const PromptSuggestionService, input: []const u8) ![]const u8 {
        const result = try self.alloc.dupe(u8, input);
        for (result) |*c| {
            c.* = std.ascii.toLower(c.*);
        }
        return result;
    }

    /// Enable or disable suggestions
    pub fn setEnabled(self: *PromptSuggestionService, enabled: bool) void {
        self.enabled = enabled;
    }
};
