//! Rich Command History Module
//!
//! This module provides enhanced command history tracking with metadata
//! including exit codes, directory details, git branch info, timestamps, and duration.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_command_history);

/// Rich command entry with full metadata
pub const RichCommandEntry = struct {
    /// The command that was executed
    command: []const u8,
    /// Exit code (0 = success, non-zero = failure)
    exit_code: i32,
    /// Working directory when command was executed
    directory: []const u8,
    /// Git branch name (if in a git repository)
    git_branch: ?[]const u8,
    /// Timestamp when command was executed
    timestamp: i64,
    /// Duration in milliseconds (if known)
    duration_ms: ?u64,
    /// Session identifier
    session_id: []const u8,

    pub fn deinit(self: *const RichCommandEntry, alloc: Allocator) void {
        alloc.free(self.command);
        alloc.free(self.directory);
        if (self.git_branch) |branch| alloc.free(branch);
        alloc.free(self.session_id);
    }
};

/// Command history storage with rich metadata
pub const RichCommandHistory = struct {
    alloc: Allocator,
    entries: std.ArrayList(RichCommandEntry),
    session_id: []const u8,
    max_entries: usize,
    command_index: StringHashMap(usize), // Maps command hash to entry index

    /// Initialize the rich command history
    pub fn init(alloc: Allocator, max_entries: usize) !RichCommandHistory {
        // Generate session ID
        const session_id = try std.fmt.allocPrint(alloc, "{d}", .{std.time.timestamp()});

        return RichCommandHistory{
            .alloc = alloc,
            .entries = std.ArrayList(RichCommandEntry).init(alloc),
            .session_id = session_id,
            .max_entries = max_entries,
            .command_index = StringHashMap(usize).init(alloc),
        };
    }

    pub fn deinit(self: *RichCommandHistory) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.alloc);
        }
        self.entries.deinit();
        self.alloc.free(self.session_id);
        self.command_index.deinit();
    }

    /// Record a command with its metadata
    pub fn recordCommand(
        self: *RichCommandHistory,
        command: []const u8,
        exit_code: i32,
        directory: []const u8,
        duration_ms: ?u64,
    ) !void {
        const alloc = self.alloc;

        // Duplicate strings
        const cmd_copy = try alloc.dupe(u8, command);
        errdefer alloc.free(cmd_copy);

        const dir_copy = try alloc.dupe(u8, directory);
        errdefer alloc.free(dir_copy);

        const session_copy = try alloc.dupe(u8, self.session_id);
        errdefer alloc.free(session_copy);

        // Detect git branch
        const git_branch = try self.detectGitBranch(directory);

        const entry = RichCommandEntry{
            .command = cmd_copy,
            .exit_code = exit_code,
            .directory = dir_copy,
            .git_branch = git_branch,
            .timestamp = std.time.timestamp(),
            .duration_ms = duration_ms,
            .session_id = session_copy,
        };

        // Enforce max entries limit (remove oldest if needed)
        if (self.entries.items.len >= self.max_entries) {
            const removed = self.entries.orderedRemove(0);
            removed.deinit(alloc);
        }

        try self.entries.append(entry);
    }

    /// Detect git branch for a directory
    fn detectGitBranch(self: *RichCommandHistory, directory: []const u8) !?[]const u8 {
        const alloc = self.alloc;

        // Check if .git/HEAD exists
        const git_head_path = try std.fmt.allocPrint(alloc, "{s}/.git/HEAD", .{directory});
        defer alloc.free(git_head_path);

        const file = std.fs.openFileAbsolute(git_head_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return null; // Not in a git repo
        };
        defer file.close();

        const content = file.readToEndAlloc(alloc, 1024) catch |err| {
            if (err == error.OutOfMemory) return null;
            return null;
        };
        defer alloc.free(content);

        // Parse HEAD file content: "ref: refs/heads/branch_name"
        if (std.mem.indexOf(u8, content, "ref: refs/heads/")) |idx| {
            const branch_start = idx + "ref: refs/heads/".len;
            const branch_end = std.mem.indexOfScalar(u8, content[branch_start..], '\n') orelse content.len;
            const branch_name = content[branch_start..][0..branch_end];

            // Trim whitespace
            const trimmed = std.mem.trimRight(u8, branch_name, &std.ascii.whitespace);
            return alloc.dupe(u8, trimmed) catch null;
        }

        // Detached HEAD state - show commit hash
        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
        if (trimmed.len > 0) {
            const short_hash = if (trimmed.len > 8) trimmed[0..8] else trimmed;
            return alloc.dupe(u8, short_hash) catch null;
        }

        return null;
    }

    /// Get recent commands
    pub fn getRecent(self: *const RichCommandHistory, count: usize) []const RichCommandEntry {
        const start = if (count >= self.entries.items.len)
            0
        else
            self.entries.items.len - count;

        return self.entries.items[start..];
    }

    /// Get commands in current directory
    pub fn getCommandsInDirectory(self: *const RichCommandHistory, directory: []const u8) std.ArrayList(*const RichCommandEntry) !void {
        var result = std.ArrayList(*const RichCommandEntry).init(self.alloc);

        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.directory, directory)) {
                try result.append(entry);
            }
        }

        return result;
    }

    /// Get failed commands (exit_code != 0)
    pub fn getFailedCommands(self: *const RichCommandHistory) std.ArrayList(*const RichCommandEntry) !void {
        var result = std.ArrayList(*const RichCommandEntry).init(self.alloc);

        for (self.entries.items) |*entry| {
            if (entry.exit_code != 0) {
                try result.append(entry);
            }
        }

        return result;
    }

    /// Get commands in git repository
    pub fn getCommandsInGitRepo(self: *const RichCommandHistory) std.ArrayList(*const RichCommandEntry) !void {
        var result = std.ArrayList(*const RichCommandEntry).init(self.alloc);

        for (self.entries.items) |*entry| {
            if (entry.git_branch != null) {
                try result.append(entry);
            }
        }

        return result;
    }

    /// Get commands by git branch
    pub fn getCommandsByBranch(self: *const RichCommandHistory, branch: []const u8) std.ArrayList(*const RichCommandEntry) !void {
        var result = std.ArrayList(*const RichCommandEntry).init(self.alloc);

        for (self.entries.items) |*entry| {
            if (entry.git_branch) |b| {
                if (std.mem.eql(u8, b, branch)) {
                    try result.append(entry);
                }
            }
        }

        return result;
    }

    /// Search commands by pattern
    pub fn searchCommands(self: *const RichCommandHistory, pattern: []const u8) std.ArrayList(*const RichCommandEntry) !void {
        var result = std.ArrayList(*const RichCommandEntry).init(self.alloc);

        for (self.entries.items) |*entry| {
            // Case-insensitive search in command
            const lower_cmd = try self.alloc.dupe(u8, entry.command);
            defer self.alloc.free(lower_cmd);

            for (0..lower_cmd.len) |i| {
                lower_cmd[i] = std.ascii.toLower(lower_cmd[i]);
            }

            const lower_pattern = try self.alloc.dupe(u8, pattern);
            defer self.alloc.free(lower_pattern);

            for (0..lower_pattern.len) |i| {
                lower_pattern[i] = std.ascii.toLower(lower_pattern[i]);
            }

            if (std.mem.indexOf(u8, lower_cmd, lower_pattern) != null) {
                try result.append(entry);
            }
        }

        return result;
    }

    /// Get statistics about command history
    pub const Statistics = struct {
        total_commands: usize,
        successful_commands: usize,
        failed_commands: usize,
        unique_directories: usize,
        unique_git_branches: usize,
    };

    pub fn getStatistics(self: *const RichCommandHistory) !Statistics {
        var dirs = StringHashMap(void).init(self.alloc);
        defer dirs.deinit();

        var branches = StringHashMap(void).init(self.alloc);
        defer branches.deinit();

        var successful: usize = 0;
        var failed: usize = 0;

        for (self.entries.items) |entry| {
            try dirs.put(entry.directory, {});
            if (entry.git_branch) |branch| {
                try branches.put(branch, {});
            }

            if (entry.exit_code == 0) {
                successful += 1;
            } else {
                failed += 1;
            }
        }

        return Statistics{
            .total_commands = self.entries.items.len,
            .successful_commands = successful,
            .failed_commands = failed,
            .unique_directories = dirs.count(),
            .unique_git_branches = branches.count(),
        };
    }

    /// Export history to JSON
    pub fn exportToJson(self: *const RichCommandHistory) ![]const u8 {
        var result = std.ArrayList(u8).init(self.alloc);

        try result.appendSlice("{\"commands\":[");

        var first = true;
        for (self.entries.items) |entry| {
            if (!first) try result.appendSlice(",");
            first = false;

            try result.print(
                \\{{"command":"{s}","exit_code":{d},"directory":"{s}",
                \\"git_branch":"{s}","timestamp":{d},"duration_ms":{d},
                \\"session_id":"{s}"}}
            ,
                .{
                    std.json.escapeString(&result.writer(), entry.command) catch "",
                    entry.exit_code,
                    std.json.escapeString(&result.writer(), entry.directory) catch "",
                    if (entry.git_branch) |branch|
                        std.json.escapeString(&result.writer(), branch) catch ""
                    else
                        "",
                    entry.timestamp,
                    entry.duration_ms orelse 0,
                    entry.session_id,
                },
            );
        }

        try result.appendSlice("]}");

        return result.toOwnedSlice();
    }
};
