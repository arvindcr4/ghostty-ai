//! Next Command Suggestions Module
//!
//! This module analyzes command history to suggest the next command
//! a user is likely to run based on patterns and context.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_next_command);

/// A suggested next command
pub const NextCommandSuggestion = struct {
    /// The suggested command
    command: []const u8,
    /// Confidence score (0.0-1.0)
    confidence: f32,
    /// Reason for suggestion
    reason: []const u8,
    /// Command pattern matched
    pattern: Pattern,

    pub const Pattern = enum {
        /// Sequential pattern (command A often followed by B)
        sequential,
        /// Contextual pattern (command in specific context)
        contextual,
        /// Common workflow pattern
        workflow,
        /// Error recovery pattern
        error_recovery,
    };

    pub fn deinit(self: *const NextCommandSuggestion, alloc: Allocator) void {
        alloc.free(self.command);
        alloc.free(self.reason);
    }
};

/// Command history entry
const HistoryEntry = struct {
    command: []const u8,
    timestamp: i64,
    working_dir: []const u8,
    exit_code: ?i32,
    context: ?[]const u8,
};

/// Next Command Suggestion Service
pub const NextCommandService = struct {
    alloc: Allocator,
    enabled: bool,
    max_suggestions: usize,
    history: ArrayList(HistoryEntry),

    /// Initialize the next command suggestion service
    pub fn init(alloc: Allocator, max_suggestions: usize) NextCommandService {
        return .{
            .alloc = alloc,
            .enabled = true,
            .max_suggestions = max_suggestions,
            .history = ArrayList(HistoryEntry).init(alloc),
        };
    }

    pub fn deinit(self: *NextCommandService) void {
        for (self.history.items) |entry| {
            self.alloc.free(entry.command);
            self.alloc.free(entry.working_dir);
            if (entry.context) |ctx| self.alloc.free(ctx);
        }
        self.history.deinit();
    }

    /// Add a command to history
    pub fn addCommand(
        self: *NextCommandService,
        command: []const u8,
        working_dir: []const u8,
        exit_code: ?i32,
        context: ?[]const u8,
    ) !void {
        try self.history.append(.{
            .command = try self.alloc.dupe(u8, command),
            .timestamp = std.time.timestamp(),
            .working_dir = try self.alloc.dupe(u8, working_dir),
            .exit_code = exit_code,
            .context = if (context) |c| try self.alloc.dupe(u8, c) else null,
        });

        // Keep history size manageable
        if (self.history.items.len > 1000) {
            const removed = self.history.orderedRemove(0);
            self.alloc.free(removed.command);
            self.alloc.free(removed.working_dir);
            if (removed.context) |ctx| self.alloc.free(ctx);
        }
    }

    /// Get next command suggestions based on current context
    pub fn getSuggestions(
        self: *const NextCommandService,
        current_dir: []const u8,
        recent_output: ?[]const u8,
        last_command: ?[]const u8,
    ) !ArrayList(NextCommandSuggestion) {
        var suggestions = ArrayList(NextCommandSuggestion).init(self.alloc);
        errdefer {
            for (suggestions.items) |*s| s.deinit(self.alloc);
            suggestions.deinit();
        }

        if (!self.enabled or self.history.items.len == 0) return suggestions;

        // 1. Sequential patterns - commands that often follow the last command
        if (last_command) |last| {
            try self.addSequentialSuggestions(&suggestions, last, current_dir);
        }

        // 2. Error recovery patterns - commands after errors
        if (recent_output) |output| {
            if (self.detectError(output)) {
                try self.addErrorRecoverySuggestions(&suggestions, output, current_dir);
            }
        }

        // 3. Contextual patterns - commands common in this directory
        try self.addContextualSuggestions(&suggestions, current_dir);

        // 4. Workflow patterns - common command sequences
        try self.addWorkflowSuggestions(&suggestions, current_dir);

        // Sort by confidence
        std.sort.insertion(NextCommandSuggestion, suggestions.items, {}, struct {
            fn compare(_: void, a: NextCommandSuggestion, b: NextCommandSuggestion) bool {
                return a.confidence > b.confidence;
            }
        }.compare);

        // Limit to max suggestions
        while (suggestions.items.len > self.max_suggestions) {
            const removed = suggestions.pop();
            removed.deinit(self.alloc);
        }

        return suggestions;
    }

    /// Add sequential pattern suggestions
    fn addSequentialSuggestions(
        self: *const NextCommandService,
        suggestions: *ArrayList(NextCommandSuggestion),
        last_command: []const u8,
        current_dir: []const u8,
    ) !void {
        _ = current_dir;
        // Find commands that often follow the last command
        var follow_counts = StringHashMap(u32).init(self.alloc);
        defer follow_counts.deinit();

        var last_idx: ?usize = null;
        for (self.history.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.command, last_command)) {
                last_idx = i;
            } else if (last_idx) |idx| {
                if (i == idx + 1) {
                    // This command followed the last command
                    const count = follow_counts.get(entry.command) orelse 0;
                    try follow_counts.put(entry.command, count + 1);
                }
            }
        }

        // Create suggestions from most common followers
        var iter = follow_counts.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* >= 2) { // At least 2 occurrences
                try suggestions.append(.{
                    .command = try self.alloc.dupe(u8, entry.key_ptr.*),
                    .confidence = @min(@as(f32, @floatFromInt(entry.value_ptr.*)) / 10.0, 0.9),
                    .reason = try self.alloc.dupe(u8, "Often follows this command"),
                    .pattern = .sequential,
                });
            }
        }
    }

    /// Add error recovery suggestions
    fn addErrorRecoverySuggestions(
        self: *const NextCommandService,
        suggestions: *ArrayList(NextCommandSuggestion),
        error_output: []const u8,
        current_dir: []const u8,
    ) !void {
        _ = current_dir;

        // Common error recovery patterns (safe alternatives only)
        const recovery_patterns = [_]struct {
            keyword: []const u8,
            suggestion: []const u8,
            reason: []const u8,
        }{
            .{ .keyword = "permission denied", .suggestion = "sudo ", .reason = "Try with elevated permissions" },
            .{ .keyword = "not found", .suggestion = "which ", .reason = "Check if command exists" },
            .{ .keyword = "already exists", .suggestion = "ls -la ", .reason = "Check what already exists before removing" },
            .{ .keyword = "file exists", .suggestion = "ls -la ", .reason = "Check what already exists before removing" },
            .{ .keyword = "connection refused", .suggestion = "curl -I ", .reason = "Check if service is accessible" },
            .{ .keyword = "out of space", .suggestion = "df -h", .reason = "Check disk space" },
            .{ .keyword = "no such file", .suggestion = "ls ", .reason = "Check current directory contents" },
            .{ .keyword = "command not found", .suggestion = "echo 'Check if tool is installed'", .reason = "Verify installation" },
        };

        const lower_output = try self.toLower(error_output);
        defer self.alloc.free(lower_output);

        for (recovery_patterns) |pattern| {
            if (std.mem.indexOf(u8, lower_output, pattern.keyword)) |_| {
                try suggestions.append(.{
                    .command = try self.alloc.dupe(u8, pattern.suggestion),
                    .confidence = 0.8,
                    .reason = try self.alloc.dupe(u8, pattern.reason),
                    .pattern = .error_recovery,
                });
                break; // Only add one error recovery suggestion
            }
        }
    }

    /// Add contextual suggestions based on directory
    fn addContextualSuggestions(
        self: *const NextCommandService,
        suggestions: *ArrayList(NextCommandSuggestion),
        current_dir: []const u8,
    ) !void {
        // Count commands used in this directory
        var dir_commands = StringHashMap(u32).init(self.alloc);
        defer dir_commands.deinit();

        for (self.history.items) |entry| {
            if (std.mem.eql(u8, entry.working_dir, current_dir)) {
                const count = dir_commands.get(entry.command) orelse 0;
                try dir_commands.put(entry.command, count + 1);
            }
        }

        // Suggest most common commands in this directory
        var iter = dir_commands.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* >= 3) { // At least 3 occurrences
                try suggestions.append(.{
                    .command = try self.alloc.dupe(u8, entry.key_ptr.*),
                    .confidence = @min(@as(f32, @floatFromInt(entry.value_ptr.*)) / 20.0, 0.85),
                    .reason = try self.alloc.dupe(u8, "Commonly used in this directory"),
                    .pattern = .contextual,
                });
            }
        }
    }

    /// Add workflow pattern suggestions
    fn addWorkflowSuggestions(
        self: *const NextCommandService,
        suggestions: *ArrayList(NextCommandSuggestion),
        current_dir: []const u8,
    ) !void {
        _ = current_dir;

        // Common workflow patterns
        const workflows = [_]struct {
            trigger: []const u8,
            next: []const u8,
            reason: []const u8,
        }{
            .{ .trigger = "git clone", .next = "cd ", .reason = "Navigate to cloned repository" },
            .{ .trigger = "git add", .next = "git commit -m \"", .reason = "Commit staged changes" },
            .{ .trigger = "git commit", .next = "git push", .reason = "Push committed changes" },
            .{ .trigger = "npm install", .next = "npm run", .reason = "Run project scripts" },
            .{ .trigger = "docker build", .next = "docker run", .reason = "Run built container" },
            .{ .trigger = "mkdir", .next = "cd ", .reason = "Enter new directory" },
        };

        if (self.history.items.len == 0) return;

        const last_entry = self.history.items[self.history.items.len - 1];
        const lower_last = try self.toLower(last_entry.command);
        defer self.alloc.free(lower_last);

        for (workflows) |workflow| {
            if (std.mem.indexOf(u8, lower_last, workflow.trigger)) |_| {
                try suggestions.append(.{
                    .command = try self.alloc.dupe(u8, workflow.next),
                    .confidence = 0.75,
                    .reason = try self.alloc.dupe(u8, workflow.reason),
                    .pattern = .workflow,
                });
                break;
            }
        }
    }

    /// Detect if output contains an error
    fn detectError(self: *const NextCommandService, output: []const u8) bool {
        const error_keywords = [_][]const u8{
            "error",
            "failed",
            "denied",
            "not found",
            "cannot",
            "exception",
            "fatal",
        };

        const lower = self.toLower(output) catch return false;
        defer self.alloc.free(lower);

        for (error_keywords) |keyword| {
            if (std.mem.indexOf(u8, lower, keyword)) |_| return true;
        }

        return false;
    }

    /// Convert string to lowercase
    fn toLower(self: *const NextCommandService, input: []const u8) ![]const u8 {
        const result = try self.alloc.dupe(u8, input);
        for (result) |*c| {
            c.* = std.ascii.toLower(c.*);
        }
        return result;
    }

    /// Enable or disable suggestions
    pub fn setEnabled(self: *NextCommandService, enabled: bool) void {
        self.enabled = enabled;
    }
};
