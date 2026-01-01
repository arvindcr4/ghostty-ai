//! AI Command Suggestion Service
//!
//! This module provides intelligent next-command suggestions based on
//! terminal history, current context, and common patterns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("client.zig").Client;
const ai = @import("main.zig");

/// Rich command history entry with metadata
pub const RichCommandEntry = struct {
    command: []const u8,
    exit_code: ?i32, // Exit code of the command (null if not known)
    directory: ?[]const u8, // Working directory where command was executed
    git_branch: ?[]const u8, // Git branch at time of execution (null if not in git repo)
    timestamp: i64, // Unix timestamp in milliseconds
    duration: ?i64, // Command execution duration in milliseconds (null if not known)

    pub fn deinit(self: *const RichCommandEntry, alloc: Allocator) void {
        alloc.free(self.command);
        if (self.directory) |dir| alloc.free(dir);
        if (self.git_branch) |branch| alloc.free(branch);
    }
};

/// A suggested command with metadata
pub const Suggestion = struct {
    command: []const u8,
    description: []const u8,
    confidence: f32, // 0.0 to 1.0
    source: Source,

    pub const Source = enum {
        history, // Based on command history patterns
        ai, // AI-generated suggestion
        workflow, // From saved workflows
        correction, // Typo correction
    };

    pub fn deinit(self: *const Suggestion, alloc: Allocator) void {
        alloc.free(self.command);
        alloc.free(self.description);
    }
};

/// Next Command Suggestion Service
pub const SuggestionService = struct {
    const Self = @This();

    alloc: Allocator,
    client: ?Client,
    history: std.ArrayList(RichCommandEntry),
    max_history: usize,

    /// System prompt for next command suggestions
    const suggestionPrompt =
        \\You are a terminal command predictor. Based on the recent command history,
        \\suggest the most likely next command the user will want to run.
        \\
        \\Guidelines:
        \\- Consider the workflow pattern (e.g., git add -> git commit -> git push)
        \\- Account for the current directory context if provided
        \\- Consider exit codes (non-zero may indicate errors to fix)
        \\- Consider git branch context for branch-specific workflows
        \\- Consider command duration for performance optimization
        \\- Return ONLY the suggested command, no explanation
        \\- If multiple suggestions are possible, return the most likely one
        \\
        \\Return format: Just the command on a single line.
    ;

    /// Initialize the suggestion service
    pub fn init(alloc: Allocator, config: ai.Assistant.Config) !Self {
        var client: ?Client = null;
        if (config.enabled and config.provider != null) {
            client = Client.init(
                alloc,
                config.provider.?,
                config.api_key,
                config.endpoint,
                config.model,
                100, // Short max tokens for suggestions
                0.3, // Lower temperature for more deterministic suggestions
            );
        }

        return .{
            .alloc = alloc,
            .client = client,
            .history = std.ArrayList(RichCommandEntry).init(alloc),
            .max_history = 50,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.history.items) |*entry| {
            entry.deinit(self.alloc);
        }
        self.history.deinit();
    }

    /// Record a command in history with rich metadata
    pub fn recordCommandRich(
        self: *Self,
        command: []const u8,
        exit_code: ?i32,
        directory: ?[]const u8,
        git_branch: ?[]const u8,
        duration: ?i64,
    ) !void {
        // Skip empty commands
        if (command.len == 0) return;

        // Skip duplicate of last command
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last.command, command)) return;
        }

        // Create rich command entry
        const cmd_copy = try self.alloc.dupe(u8, command);
        const dir_copy = if (directory) |dir| try self.alloc.dupe(u8, dir) else null;
        const branch_copy = if (git_branch) |branch| try self.alloc.dupe(u8, branch) else null;
        
        const entry = RichCommandEntry{
            .command = cmd_copy,
            .exit_code = exit_code,
            .directory = dir_copy,
            .git_branch = branch_copy,
            .timestamp = std.time.milliTimestamp(),
            .duration = duration,
        };

        // Add to history
        try self.history.append(entry);

        // Trim if over max
        while (self.history.items.len > self.max_history) {
            const old = self.history.orderedRemove(0);
            old.deinit(self.alloc);
        }
    }

    /// Record a command in history (simplified version for backward compatibility)
    pub fn recordCommand(self: *Self, command: []const u8) !void {
        try self.recordCommandRich(command, null, null, null, null);
    }

    /// Get next command suggestions
    pub fn getSuggestions(self: *Self, context: ?[]const u8) !std.ArrayList(Suggestion) {
        var suggestions = std.ArrayList(Suggestion).init(self.alloc);
        errdefer {
            for (suggestions.items) |*s| s.deinit(self.alloc);
            suggestions.deinit();
        }

        // Pattern-based suggestions from history
        try self.addHistoryPatternSuggestions(&suggestions);

        // AI-based suggestion if available
        if (self.client) |*client| {
            try self.addAiSuggestion(client, &suggestions, context);
        }

        return suggestions;
    }

    /// Add suggestions based on command history patterns
    fn addHistoryPatternSuggestions(self: *Self, suggestions: *std.ArrayList(Suggestion)) !void {
        if (self.history.items.len < 2) return;

        const last_cmd = self.history.items[self.history.items.len - 1].command;

        // Common workflow patterns
        const patterns = [_]struct { prev: []const u8, next: []const u8, desc: []const u8 }{
            // Git workflow
            .{ .prev = "git add", .next = "git commit -m \"\"", .desc = "Commit staged changes" },
            .{ .prev = "git commit", .next = "git push", .desc = "Push commits to remote" },
            .{ .prev = "git pull", .next = "git status", .desc = "Check status after pull" },
            .{ .prev = "git checkout", .next = "git pull", .desc = "Pull latest changes" },
            // Build workflows
            .{ .prev = "npm install", .next = "npm run build", .desc = "Build after install" },
            .{ .prev = "npm run build", .next = "npm start", .desc = "Start after build" },
            .{ .prev = "cargo build", .next = "cargo run", .desc = "Run after build" },
            .{ .prev = "cargo test", .next = "cargo build --release", .desc = "Release build after tests" },
            .{ .prev = "zig build", .next = "zig build test", .desc = "Run tests" },
            .{ .prev = "make", .next = "make test", .desc = "Run tests after build" },
            // Python workflows
            .{ .prev = "pip install", .next = "python", .desc = "Start Python" },
            .{ .prev = "pytest", .next = "python", .desc = "Run Python after tests" },
            // Docker workflows
            .{ .prev = "docker build", .next = "docker run", .desc = "Run container" },
            .{ .prev = "docker-compose up", .next = "docker-compose logs", .desc = "View logs" },
        };

        for (patterns) |pattern| {
            if (std.mem.startsWith(u8, last_cmd, pattern.prev)) {
                try suggestions.append(.{
                    .command = try self.alloc.dupe(u8, pattern.next),
                    .description = try self.alloc.dupe(u8, pattern.desc),
                    .confidence = 0.8,
                    .source = .history,
                });
                break;
            }
        }
    }

    /// Add AI-generated suggestion
    fn addAiSuggestion(
        self: *Self,
        client: *Client,
        suggestions: *std.ArrayList(Suggestion),
        context: ?[]const u8,
    ) !void {
        // Build prompt from recent history
        var prompt_buf = std.ArrayList(u8).init(self.alloc);
        defer prompt_buf.deinit();

        const writer = prompt_buf.writer();
        try writer.writeAll("Recent commands:\n");

        // Include last 5 commands with rich metadata
        const start = if (self.history.items.len > 5) self.history.items.len - 5 else 0;
        for (self.history.items[start..]) |entry| {
            try writer.print("$ {s}", .{entry.command});
            
            // Add metadata if available
            var has_metadata = false;
            if (entry.exit_code) |code| {
                try writer.print(" [exit: {d}]", .{code});
                has_metadata = true;
            }
            if (entry.directory) |dir| {
                try writer.print(" [dir: {s}]", .{dir});
                has_metadata = true;
            }
            if (entry.git_branch) |branch| {
                try writer.print(" [git: {s}]", .{branch});
                has_metadata = true;
            }
            if (entry.duration) |duration| {
                try writer.print(" [time: {d}ms]", .{duration});
                has_metadata = true;
            }
            try writer.writeAll("\n");
        }

        if (context) |ctx| {
            try writer.print("\nCurrent context: {s}\n", .{ctx});
        }

        try writer.writeAll("\nWhat command should the user run next?");

        // Get AI suggestion
        const response = client.chat(suggestionPrompt, prompt_buf.items) catch return;

        // Parse the response - just take the first line as the command
        var lines = std.mem.splitScalar(u8, response.content, '\n');
        if (lines.next()) |first_line| {
            const trimmed = std.mem.trim(u8, first_line, " \t$");
            if (trimmed.len > 0) {
                try suggestions.append(.{
                    .command = try self.alloc.dupe(u8, trimmed),
                    .description = try self.alloc.dupe(u8, "AI suggested"),
                    .confidence = 0.6,
                    .source = .ai,
                });
            }
        }
    }

    /// Get command correction if the last command looks like a typo
    pub fn getCorrection(self: *Self, failed_command: []const u8) !?Suggestion {
        // Common typo corrections
        const corrections = [_]struct { typo: []const u8, fix: []const u8 }{
            .{ .typo = "gti", .fix = "git" },
            .{ .typo = "got", .fix = "git" },
            .{ .typo = "gi t", .fix = "git" },
            .{ .typo = "npx", .fix = "npm" },
            .{ .typo = "pyton", .fix = "python" },
            .{ .typo = "ptyhon", .fix = "python" },
            .{ .typo = "suod", .fix = "sudo" },
            .{ .typo = "sduo", .fix = "sudo" },
            .{ .typo = "cta", .fix = "cat" },
            .{ .typo = "gerp", .fix = "grep" },
            .{ .typo = "sl", .fix = "ls" },
            .{ .typo = "cd..", .fix = "cd .." },
            .{ .typo = "cdd", .fix = "cd" },
        };

        for (corrections) |corr| {
            if (std.mem.startsWith(u8, failed_command, corr.typo)) {
                const rest = failed_command[corr.typo.len..];
                const fixed = try self.alloc.alloc(u8, corr.fix.len + rest.len);
                @memcpy(fixed[0..corr.fix.len], corr.fix);
                @memcpy(fixed[corr.fix.len..], rest);

                return Suggestion{
                    .command = fixed,
                    .description = try self.alloc.dupe(u8, "Did you mean this?"),
                    .confidence = 0.9,
                    .source = .correction,
                };
            }
        }

        return null;
    }
};
