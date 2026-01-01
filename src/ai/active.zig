//! Active AI - Proactive Contextual Recommendations
//!
//! This module provides proactive AI assistance that automatically detects
//! terminal activity patterns and offers contextual recommendations without
//! requiring an explicit user prompt. This is similar to Warp's "Active AI"
//! feature that observes terminal state and suggests helpful actions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Client = @import("client.zig").Client;
const ai = @import("main.zig");

/// Active AI trigger events
pub const TriggerEvent = enum {
    command_failed, // Command exited with non-zero code
    command_slow, // Command took unusually long
    error_output, // Error patterns detected in output
    file_created, // New file created in current directory
    git_status_changed, // Git working directory changed
    directory_changed, // Working directory changed
    idle_timeout, // User idle after command completion
    pattern_detected, // Recognized workflow pattern
};

/// Active AI recommendation
pub const Recommendation = struct {
    title: []const u8,
    description: []const u8,
    action: Action,
    confidence: f32, // 0.0 to 1.0
    trigger: TriggerEvent,

    pub const Action = union(enum) {
        suggest_command: struct {
            command: []const u8,
            explanation: []const u8,
        },
        show_explanation: struct {
            topic: []const u8,
            content: []const u8,
        },
        offer_correction: struct {
            original: []const u8,
            correction: []const u8,
            reason: []const u8,
        },
        suggest_workflow: struct {
            name: []const u8,
            steps: []const []const u8,
        },
        show_tip: struct {
            tip: []const u8,
        },
    };

    pub fn deinit(self: *const Recommendation, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.description);

        switch (self.action) {
            .suggest_command => |a| {
                alloc.free(a.command);
                alloc.free(a.explanation);
            },
            .show_explanation => |a| {
                alloc.free(a.topic);
                alloc.free(a.content);
            },
            .offer_correction => |a| {
                alloc.free(a.original);
                alloc.free(a.correction);
                alloc.free(a.reason);
            },
            .suggest_workflow => |a| {
                alloc.free(a.name);
                for (a.steps) |step| alloc.free(step);
                alloc.free(a.steps);
            },
            .show_tip => |a| {
                alloc.free(a.tip);
            },
        }
    }
};

/// Terminal state snapshot for pattern detection
pub const TerminalState = struct {
    last_command: []const u8,
    exit_code: ?i32,
    duration_ms: ?i64,
    current_directory: []const u8,
    git_branch: ?[]const u8,
    git_status: ?GitStatus,
    error_output: ?[]const u8,
    timestamp: i64,

    pub const GitStatus = struct {
        staged: usize,
        modified: usize,
        untracked: usize,
        branch: []const u8,
    };

    pub fn deinit(self: *const TerminalState, alloc: Allocator) void {
        alloc.free(self.last_command);
        alloc.free(self.current_directory);
        if (self.git_branch) |b| alloc.free(b);
        if (self.git_status) |*s| alloc.free(s.branch);
        if (self.error_output) |e| alloc.free(e);
    }
};

/// Active AI Service
pub const ActiveAI = struct {
    const Self = @This();

    alloc: Allocator,
    client: ?Client,
    redactor: ?*ai.Redactor,
    enabled_triggers: u32, // Bitmask for TriggerEvent values
    command_history: std.ArrayList([]const u8),
    last_state: ?TerminalState,
    idle_threshold_ms: i64,
    slow_command_threshold_ms: i64,

    /// System prompt for active AI recommendations
    const activeAiPrompt =
        \\You are a proactive terminal assistant. Analyze the terminal state and
        \\suggest helpful actions the user might want to take.
        \\
        \\Guidelines:
        \\- Be concise and actionable
        \\- Focus on fixing errors, improving workflows, or saving time
        \\- Explain WHY the suggestion is helpful
        \\- Don't suggest basic commands the user clearly knows
        \\- Consider command exit codes, duration, and output
        \\
        \\Return format: A JSON object with "title", "description", and "action" fields.
    ;

    pub fn init(alloc: Allocator, config: ai.Assistant.Config, redactor: ?*ai.Redactor) !Self {
        var client: ?Client = null;
        if (config.enabled and config.provider != null) {
            client = Client.init(
                alloc,
                config.provider.?,
                config.api_key,
                config.endpoint,
                config.model,
                500, // Moderate max tokens for recommendations
                0.5, // Balanced temperature
            );
        }

        // Enable all triggers by default (bitmask with all bits set for first 8 triggers)
        const enabled_triggers: u32 = 0xFF;

        return .{
            .alloc = alloc,
            .client = client,
            .redactor = redactor,
            .enabled_triggers = enabled_triggers,
            .command_history = std.ArrayList([]const u8).init(alloc),
            .last_state = null,
            .idle_threshold_ms = 30000, // 30 seconds
            .slow_command_threshold_ms = 5000, // 5 seconds
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.last_state) |*s| s.deinit(self.alloc);

        for (self.command_history.items) |cmd| {
            self.alloc.free(cmd);
        }
        self.command_history.deinit();
    }

    /// Process a terminal state change and return proactive recommendations
    pub fn processStateChange(
        self: *Self,
        state: TerminalState,
    ) !std.ArrayList(Recommendation) {
        var recommendations = std.ArrayList(Recommendation).init(self.alloc);
        errdefer {
            for (recommendations.items) |*r| r.deinit(self.alloc);
            recommendations.deinit();
        }

        // Check if trigger is enabled
        const trigger = try self.detectTrigger(&state);
        if (trigger) |t| {
            const trigger_bit: u32 = 1 << @intFromEnum(t);
            if ((self.enabled_triggers & trigger_bit) == 0) {
                return recommendations;
            }

            // Generate recommendations based on trigger
            try self.generateRecommendations(t, &state, &recommendations);
        }

        // Update last state
        if (self.last_state) |*old| old.deinit(self.alloc);
        self.last_state = state;

        return recommendations;
    }

    /// Detect what triggered the state change
    fn detectTrigger(self: *Self, state: *const TerminalState) !?TriggerEvent {
        // Command failed
        if (state.exit_code) |code| {
            if (code != 0) return .command_failed;
        }

        // Slow command
        if (state.duration_ms) |duration| {
            if (duration > self.slow_command_threshold_ms) return .command_slow;
        }

        // Error output
        if (state.error_output) |output| {
            if (output.len > 0) return .error_output;
        }

        // Git status changed
        if (state.git_status) |status| {
            if (self.last_state) |last| {
                if (last.git_status == null or
                    !std.mem.eql(u8, last.git_status.?.branch, status.branch))
                {
                    return .git_status_changed;
                }
            }
        }

        // Directory changed
        if (self.last_state) |last| {
            if (!std.mem.eql(u8, last.current_directory, state.current_directory)) {
                return .directory_changed;
            }
        }

        // Pattern detection from command history
        if (try self.detectWorkflowPattern()) {
            return .pattern_detected;
        }

        return null;
    }

    /// Detect known workflow patterns
    fn detectWorkflowPattern(self: *Self) !bool {
        if (self.command_history.items.len < 2) return false;

        const last = self.command_history.items[self.command_history.items.len - 1];
        const second_last = self.command_history.items[self.command_history.items.len - 2];

        // Git workflow patterns
        if (std.mem.indexOf(u8, second_last, "git add") != null and
            std.mem.indexOf(u8, last, "git commit") != null)
        {
            return true;
        }

        // Build workflow patterns
        if (std.mem.indexOf(u8, second_last, "build") != null and
            std.mem.indexOf(u8, last, "test") != null)
        {
            return true;
        }

        return false;
    }

    /// Generate recommendations based on trigger
    fn generateRecommendations(
        self: *Self,
        trigger: TriggerEvent,
        state: *const TerminalState,
        recommendations: *std.ArrayList(Recommendation),
    ) !void {
        switch (trigger) {
            .command_failed => try self.handleCommandFailed(state, recommendations),
            .command_slow => try self.handleSlowCommand(state, recommendations),
            .error_output => try self.handleErrorOutput(state, recommendations),
            .git_status_changed => try self.handleGitStatusChanged(state, recommendations),
            .directory_changed => try self.handleDirectoryChanged(state, recommendations),
            .pattern_detected => try self.handlePatternDetected(state, recommendations),
            else => {},
        }
    }

    /// Handle failed command
    fn handleCommandFailed(
        self: *Self,
        state: *const TerminalState,
        recommendations: *std.ArrayList(Recommendation),
    ) !void {
        const cmd = state.last_command;

        // Common error patterns and fixes
        const error_fixes = [_]struct {
            pattern: []const u8,
            fix: []const u8,
            reason: []const u8,
        }{
            .{ .pattern = "command not found", .fix = "Check spelling and install the command", .reason = "The command doesn't exist on your system" },
            .{ .pattern = "permission denied", .fix = "sudo ", .reason = "Try running with elevated privileges" },
            .{ .pattern = "No such file or directory", .fix = "ls", .reason = "List files to check current directory" },
            .{ .pattern = "connection refused", .fix = "Check if the service is running", .reason = "Service might not be started" },
            .{ .pattern = "address already in use", .fix = "lsof -i :<port>", .reason = "Find what's using the port" },
        };

        // Check error output first
        if (state.error_output) |err| {
            for (error_fixes) |fix| {
                if (std.mem.indexOf(u8, err, fix.pattern) != null) {
                    const correction = try self.alloc.alloc(u8, fix.fix.len + cmd.len + 1);
                    @memcpy(correction[0..fix.fix.len], fix.fix);
                    @memcpy(correction[fix.fix.len..], cmd);
                    correction[fix.fix.len + cmd.len] = 0;

                    try recommendations.append(.{
                        .title = try self.alloc.dupe(u8, "Fix Failed Command"),
                        .description = try self.alloc.dupe(u8, fix.reason),
                        .action = .{ .offer_correction = .{
                            .original = try self.alloc.dupe(u8, cmd),
                            .correction = correction[0 .. correction.len - 1 :0],
                            .reason = try self.alloc.dupe(u8, fix.reason),
                        } },
                        .confidence = 0.8,
                        .trigger = .command_failed,
                    });
                    return;
                }
            }
        }

        // If AI client available, get intelligent suggestion
        if (self.client) |*client| {
            const recommendation = try self.getAiRecommendation(client, state);
            if (recommendation) |r| {
                try recommendations.append(r);
            }
        }
    }

    /// Handle slow command
    fn handleSlowCommand(
        self: *Self,
        state: *const TerminalState,
        recommendations: *std.ArrayList(Recommendation),
    ) !void {
        _ = state;

        try recommendations.append(.{
            .title = try self.alloc.dupe(u8, "Optimize Slow Command"),
            .description = try self.alloc.dupe(u8,
                \\This command took longer than expected. Consider:
                \\- Using parallel processing (e.g., make -j)
                \\- Caching results
                \\- Using faster alternatives
            ),
            .action = .{ .show_tip = .{
                .tip = try self.alloc.dupe(u8, "Monitor command performance with 'time' prefix"),
            } },
            .confidence = 0.6,
            .trigger = .command_slow,
        });
    }

    /// Handle error output
    fn handleErrorOutput(
        self: *Self,
        state: *const TerminalState,
        recommendations: *std.ArrayList(Recommendation),
    ) !void {
        if (state.error_output) |err| {
            // Check for common error patterns
            if (std.mem.indexOf(u8, err, "deprecated") != null) {
                try recommendations.append(.{
                    .title = try self.alloc.dupe(u8, "Update Deprecated Usage"),
                    .description = try self.alloc.dupe(u8, "This command uses deprecated features"),
                    .action = .{ .show_tip = .{
                        .tip = try self.alloc.dupe(u8, "Check the documentation for modern alternatives"),
                    } },
                    .confidence = 0.7,
                    .trigger = .error_output,
                });
            }
        }
    }

    /// Handle git status changed
    fn handleGitStatusChanged(
        self: *Self,
        state: *const TerminalState,
        recommendations: *std.ArrayList(Recommendation),
    ) !void {
        if (state.git_status) |status| {
            if (status.modified > 0 or status.staged > 0) {
                try recommendations.append(.{
                    .title = try self.alloc.dupe(u8, "Git Changes Detected"),
                    .description = try self.alloc.dupe(u8,
                        \\You have uncommitted changes. Consider committing them.
                    ),
                    .action = .{ .suggest_command = .{
                        .command = try self.alloc.dupe(u8, "git status"),
                        .explanation = try self.alloc.dupe(u8, "Review your changes before committing"),
                    } },
                    .confidence = 0.75,
                    .trigger = .git_status_changed,
                });
            }
        }
    }

    /// Handle directory changed
    fn handleDirectoryChanged(
        self: *Self,
        state: *const TerminalState,
        recommendations: *std.ArrayList(Recommendation),
    ) !void {
        _ = state;

        // Could suggest ls or other directory-aware commands
        try recommendations.append(.{
            .title = try self.alloc.dupe(u8, "New Directory"),
            .description = try self.alloc.dupe(u8, "You've changed to a new directory"),
            .action = .{ .suggest_command = .{
                .command = try self.alloc.dupe(u8, "ls -la"),
                .explanation = try self.alloc.dupe(u8, "List directory contents with details"),
            } },
            .confidence = 0.5,
            .trigger = .directory_changed,
        });
    }

    /// Handle pattern detected
    fn handlePatternDetected(
        self: *Self,
        state: *const TerminalState,
        recommendations: *std.ArrayList(Recommendation),
    ) !void {
        _ = state;

        if (self.command_history.items.len >= 2) {
            const last = self.command_history.items[self.command_history.items.len - 1];
            const second_last = self.command_history.items[self.command_history.items.len - 2];

            // Git workflow: add -> commit
            if (std.mem.indexOf(u8, second_last, "git add") != null and
                std.mem.indexOf(u8, last, "git commit") != null)
            {
                try recommendations.append(.{
                    .title = try self.alloc.dupe(u8, "Complete Git Workflow"),
                    .description = try self.alloc.dupe(u8, "You've staged and committed changes"),
                    .action = .{ .suggest_command = .{
                        .command = try self.alloc.dupe(u8, "git push"),
                        .explanation = try self.alloc.dupe(u8, "Push your commits to the remote repository"),
                    } },
                    .confidence = 0.85,
                    .trigger = .pattern_detected,
                });
            }
        }
    }

    /// Get AI-powered recommendation
    fn getAiRecommendation(
        self: *Self,
        client: *Client,
        state: *const TerminalState,
    ) !?Recommendation {
        var prompt_buf = std.ArrayList(u8).init(self.alloc);
        defer prompt_buf.deinit();

        const writer = prompt_buf.writer();

        try writer.print("Last command: {s}\n", .{state.last_command});
        if (state.exit_code) |code| {
            try writer.print("Exit code: {d}\n", .{code});
        }
        if (state.error_output) |err| {
            try writer.print("Error output:\n{s}\n", .{err});
        }

        // Redact sensitive information if enabled
        const prompt_content = prompt_buf.items;
        const redacted_prompt = if (self.redactor != null)
            try self.redactor.?.redact(prompt_content)
        else
            prompt_content;
        defer if (self.redactor != null) self.alloc.free(redacted_prompt);

        const response = client.chat(activeAiPrompt, redacted_prompt) catch return null;

        // Parse AI response (simplified - real implementation would parse JSON)
        return Recommendation{
            .title = try self.alloc.dupe(u8, "AI Suggestion"),
            .description = try self.alloc.dupe(u8, response.content),
            .action = .{ .show_explanation = .{
                .topic = try self.alloc.dupe(u8, "AI Analysis"),
                .content = try self.alloc.dupe(u8, response.content),
            } },
            .confidence = 0.7,
            .trigger = .command_failed,
        };
    }

    /// Record a command in history
    pub fn recordCommand(self: *Self, command: []const u8) !void {
        const cmd_copy = try self.alloc.dupe(u8, command);
        try self.command_history.append(cmd_copy);

        // Keep last 100 commands
        while (self.command_history.items.len > 100) {
            const old = self.command_history.orderedRemove(0);
            self.alloc.free(old);
        }
    }
};
