//! Rich Command History Module
//!
//! This module extends command history with metadata like execution time,
//! exit codes, working directory, git context, and more.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_rich_history);

/// Rich command history entry with metadata
pub const RichHistoryEntry = struct {
    /// The command that was executed
    command: []const u8,
    /// Timestamp when command was executed
    timestamp: i64,
    /// Working directory when command was executed
    working_directory: []const u8,
    /// Exit code (null if still running or unknown)
    exit_code: ?i32,
    /// Execution duration in milliseconds
    duration_ms: ?i64,
    /// Git branch at time of execution
    git_branch: ?[]const u8,
    /// Git commit hash
    git_commit: ?[]const u8,
    /// Whether command had errors in output
    had_errors: bool,
    /// Output preview (first few lines)
    output_preview: ?[]const u8,
    /// Tags for categorization
    tags: ArrayList([]const u8),
    /// User notes/annotations
    notes: ?[]const u8,
    /// Whether this command was successful
    success: bool,
    /// Command type/category
    command_type: CommandType,

    /// Category of command for filtering and analysis
    pub const CommandType = enum {
        /// File system operations (ls, cd, cp, mv, etc.)
        file_operation,
        /// Git version control commands
        git_operation,
        /// Build and compilation commands
        build_operation,
        /// Test execution commands
        test_operation,
        /// Network and HTTP operations
        network_operation,
        /// System administration commands
        system_operation,
        /// User-defined or unrecognized commands
        custom,
    };

    /// Create a new history entry with default values
    pub fn init(alloc: Allocator) RichHistoryEntry {
        return .{
            .command = "", // Set by caller after init
            .timestamp = std.time.timestamp(),
            .working_directory = "",
            .exit_code = null,
            .duration_ms = null,
            .git_branch = null,
            .git_commit = null,
            .had_errors = false,
            .output_preview = null,
            .tags = ArrayList([]const u8).init(alloc),
            .notes = null,
            .success = false,
            .command_type = .custom,
        };
    }

    /// Free all allocated resources for this entry
    pub fn deinit(self: *RichHistoryEntry, alloc: Allocator) void {
        alloc.free(self.command);
        alloc.free(self.working_directory);
        if (self.git_branch) |b| alloc.free(b);
        if (self.git_commit) |c| alloc.free(c);
        if (self.output_preview) |p| alloc.free(p);
        for (self.tags.items) |tag| alloc.free(tag);
        self.tags.deinit();
        if (self.notes) |n| alloc.free(n);
    }

    /// Detect command type from command string
    pub fn detectCommandType(self: *RichHistoryEntry) void {
        const cmd = self.command;
        if (std.mem.startsWith(u8, cmd, "git ")) {
            self.command_type = .git_operation;
        } else if (std.mem.indexOf(u8, cmd, "build") != null or
            std.mem.indexOf(u8, cmd, "make") != null or
            std.mem.indexOf(u8, cmd, "compile") != null)
        {
            self.command_type = .build_operation;
        } else if (std.mem.indexOf(u8, cmd, "test") != null) {
            self.command_type = .test_operation;
        } else if (std.mem.startsWith(u8, cmd, "curl ") or
            std.mem.startsWith(u8, cmd, "wget ") or
            std.mem.startsWith(u8, cmd, "ssh ") or
            std.mem.startsWith(u8, cmd, "scp "))
        {
            self.command_type = .network_operation;
        } else if (std.mem.startsWith(u8, cmd, "ls ") or
            std.mem.startsWith(u8, cmd, "cd ") or
            std.mem.startsWith(u8, cmd, "mkdir ") or
            std.mem.startsWith(u8, cmd, "rm ") or
            std.mem.startsWith(u8, cmd, "cp ") or
            std.mem.startsWith(u8, cmd, "mv "))
        {
            self.command_type = .file_operation;
        } else if (std.mem.startsWith(u8, cmd, "sudo ") or
            std.mem.startsWith(u8, cmd, "systemctl ") or
            std.mem.startsWith(u8, cmd, "ps ") or
            std.mem.startsWith(u8, cmd, "kill "))
        {
            self.command_type = .system_operation;
        }
    }

    /// Add a tag
    pub fn addTag(self: *RichHistoryEntry, alloc: Allocator, tag: []const u8) !void {
        try self.tags.append(try alloc.dupe(u8, tag));
    }

    /// Set notes
    pub fn setNotes(self: *RichHistoryEntry, alloc: Allocator, notes: []const u8) !void {
        if (self.notes) |old| alloc.free(old);
        self.notes = try alloc.dupe(u8, notes);
    }
};

/// Rich History Manager
pub const RichHistoryManager = struct {
    alloc: Allocator,
    entries: ArrayList(RichHistoryEntry),
    storage_path: []const u8,
    max_entries: usize,

    /// Initialize rich history manager
    pub fn init(alloc: Allocator, max_entries: usize) !RichHistoryManager {
        const home = std.os.getenv("HOME") orelse return error.HomeNotSet;
        const storage_path = try std.fs.path.join(alloc, &.{ home, ".config", "ghostty", "rich_history" });

        // Create directory if it doesn't exist
        std.fs.makeDirAbsolute(storage_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return RichHistoryManager{
            .alloc = alloc,
            .entries = ArrayList(RichHistoryEntry).init(alloc),
            .storage_path = storage_path,
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *RichHistoryManager) void {
        for (self.entries.items) |*entry| entry.deinit(self.alloc);
        self.entries.deinit();
        self.alloc.free(self.storage_path);
    }

    /// Add a command to history
    pub fn addCommand(
        self: *RichHistoryManager,
        command: []const u8,
        working_directory: []const u8,
    ) !*RichHistoryEntry {
        var entry = RichHistoryEntry.init(self.alloc);
        entry.command = try self.alloc.dupe(u8, command);
        entry.working_directory = try self.alloc.dupe(u8, working_directory);
        entry.detectCommandType();

        try self.entries.append(entry);

        // Limit history size
        if (self.entries.items.len > self.max_entries) {
            const removed = self.entries.orderedRemove(0);
            removed.deinit(self.alloc);
        }

        return &self.entries.items[self.entries.items.len - 1];
    }

    /// Update entry with execution results
    pub fn updateEntry(
        self: *RichHistoryManager,
        entry: *RichHistoryEntry,
        exit_code: ?i32,
        duration_ms: ?i64,
        output_preview: ?[]const u8,
    ) !void {
        entry.exit_code = exit_code;
        entry.duration_ms = duration_ms;
        entry.success = exit_code == 0;
        if (output_preview) |preview| {
            entry.output_preview = try self.alloc.dupe(u8, preview);
        }
    }

    /// Search history by query
    pub fn search(self: *const RichHistoryManager, query: []const u8) !ArrayList(*const RichHistoryEntry) {
        var results = ArrayList(*const RichHistoryEntry).init(self.alloc);
        const lower_query = try self.toLower(query);
        defer self.alloc.free(lower_query);

        for (self.entries.items) |*entry| {
            // Search in command
            const lower_cmd = try self.toLower(entry.command);
            defer self.alloc.free(lower_cmd);
            if (std.mem.indexOf(u8, lower_cmd, lower_query) != null) {
                try results.append(entry);
                continue;
            }

            // Search in tags
            for (entry.tags.items) |tag| {
                const lower_tag = try self.toLower(tag);
                defer self.alloc.free(lower_tag);
                if (std.mem.indexOf(u8, lower_tag, lower_query) != null) {
                    try results.append(entry);
                    break;
                }
            }

            // Search in notes
            if (entry.notes) |notes| {
                const lower_notes = try self.toLower(notes);
                defer self.alloc.free(lower_notes);
                if (std.mem.indexOf(u8, lower_notes, lower_query) != null) {
                    try results.append(entry);
                }
            }
        }

        return results;
    }

    /// Filter by command type
    pub fn filterByType(
        self: *const RichHistoryManager,
        command_type: RichHistoryEntry.CommandType,
    ) !ArrayList(*const RichHistoryEntry) {
        var results = ArrayList(*const RichHistoryEntry).init(self.alloc);

        for (self.entries.items) |*entry| {
            if (entry.command_type == command_type) {
                try results.append(entry);
            }
        }

        return results;
    }

    /// Filter by success/failure
    pub fn filterBySuccess(
        self: *const RichHistoryManager,
        success: bool,
    ) !ArrayList(*const RichHistoryEntry) {
        var results = ArrayList(*const RichHistoryEntry).init(self.alloc);

        for (self.entries.items) |*entry| {
            if (entry.success == success) {
                try results.append(entry);
            }
        }

        return results;
    }

    /// Get recent entries
    pub fn getRecent(
        self: *const RichHistoryManager,
        limit: usize,
    ) ArrayList(*const RichHistoryEntry) {
        var results = ArrayList(*const RichHistoryEntry).init(self.alloc);

        const start = if (self.entries.items.len > limit)
            self.entries.items.len - limit
        else
            0;

        for (self.entries.items[start..]) |*entry| {
            results.append(entry) catch break;
        }

        return results;
    }

    /// Get statistics
    pub fn getStatistics(self: *const RichHistoryManager) struct {
        total_commands: usize,
        successful_commands: usize,
        failed_commands: usize,
        avg_duration_ms: ?f64,
        most_used_command: ?[]const u8,
    } {
        var stats = struct {
            total_commands: usize,
            successful_commands: usize,
            failed_commands: usize,
            avg_duration_ms: ?f64,
            most_used_command: ?[]const u8,
        }{
            .total_commands = self.entries.items.len,
            .successful_commands = 0,
            .failed_commands = 0,
            .avg_duration_ms = null,
            .most_used_command = null,
        };

        var command_counts = StringHashMap(u32).init(self.alloc);
        defer command_counts.deinit();

        var total_duration: i64 = 0;
        var duration_count: usize = 0;

        for (self.entries.items) |*entry| {
            if (entry.success) {
                stats.successful_commands += 1;
            } else if (entry.exit_code != null and entry.exit_code.? != 0) {
                stats.failed_commands += 1;
            }

            if (entry.duration_ms) |dur| {
                total_duration += dur;
                duration_count += 1;
            }

            const count = command_counts.get(entry.command) orelse 0;
            command_counts.put(entry.command, count + 1) catch {};
        }

        if (duration_count > 0) {
            stats.avg_duration_ms = @as(f64, @floatFromInt(total_duration)) / @as(f64, @floatFromInt(duration_count));
        }

        // Find most used command
        var max_count: u32 = 0;
        var iter = command_counts.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* > max_count) {
                max_count = entry.value_ptr.*;
                stats.most_used_command = entry.key_ptr.*;
            }
        }

        return stats;
    }

    /// Convert string to lowercase
    fn toLower(self: *const RichHistoryManager, input: []const u8) ![]const u8 {
        const result = try self.alloc.dupe(u8, input);
        for (result) |*c| {
            c.* = std.ascii.toLower(c.*);
        }
        return result;
    }
};
