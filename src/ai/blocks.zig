//! Block-based Commands Module
//!
//! This module provides grouping of related commands into blocks for
//! better organization and execution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.ai_blocks);

/// A command block - groups related commands
pub const CommandBlock = struct {
    /// Unique identifier
    id: []const u8,
    /// Block title/name
    title: []const u8,
    /// Description of what this block does
    description: []const u8,
    /// Commands in this block
    commands: ArrayList([]const u8),
    /// Block type/category
    block_type: Type,
    /// Created timestamp
    created_at: i64,
    /// Execution metadata
    execution_count: u32,
    last_executed: i64,

    pub const Type = enum {
        /// Sequential commands (run one after another)
        sequential,
        /// Parallel commands (can run simultaneously)
        parallel,
        /// Conditional block (run based on conditions)
        conditional,
        /// Error recovery block
        error_recovery,
    };

    pub fn init(alloc: Allocator, id: []const u8, title: []const u8) CommandBlock {
        return .{
            .id = id,
            .title = title,
            .description = "",
            .commands = ArrayList([]const u8).init(alloc),
            .block_type = .sequential,
            .created_at = std.time.timestamp(),
            .execution_count = 0,
            .last_executed = 0,
        };
    }

    pub fn deinit(self: *CommandBlock, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.description);
        for (self.commands.items) |cmd| alloc.free(cmd);
        self.commands.deinit();
    }

    /// Add a command to the block
    pub fn addCommand(self: *CommandBlock, alloc: Allocator, command: []const u8) !void {
        try self.commands.append(try alloc.dupe(u8, command));
    }

    /// Mark block as executed
    pub fn markExecuted(self: *CommandBlock) void {
        self.execution_count += 1;
        self.last_executed = std.time.timestamp();
    }

    /// Get all commands as a single string (for display)
    pub fn getCommandsText(self: *const CommandBlock, alloc: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(alloc);
        errdefer buf.deinit();

        for (self.commands.items, 0..) |cmd, i| {
            if (i > 0) try buf.append('\n');
            try buf.appendSlice(cmd);
        }

        return buf.toOwnedSlice();
    }
};

/// Block execution result
pub const BlockExecutionResult = struct {
    block_id: []const u8,
    success: bool,
    executed_commands: u32,
    failed_commands: u32,
    execution_time_ms: u64,
    results: ArrayList(?i32), // Exit codes

    pub fn deinit(self: *BlockExecutionResult, alloc: Allocator) void {
        alloc.free(self.block_id);
        self.results.deinit();
    }
};

/// Block Manager
pub const BlockManager = struct {
    alloc: Allocator,
    blocks: std.StringHashMap(*CommandBlock),

    /// Initialize block manager
    pub fn init(alloc: Allocator) BlockManager {
        return .{
            .alloc = alloc,
            .blocks = std.StringHashMap(*CommandBlock).init(alloc),
        };
    }

    pub fn deinit(self: *BlockManager) void {
        var iter = self.blocks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.blocks.deinit();
    }

    /// Create a new command block
    pub fn createBlock(self: *BlockManager, title: []const u8) !*CommandBlock {
        const id = try std.fmt.allocPrint(self.alloc, "block_{d}", .{std.time.timestamp()});
        const block = try self.alloc.create(CommandBlock);
        block.* = CommandBlock.init(self.alloc, id, title);
        block.title = try self.alloc.dupe(u8, title);

        try self.blocks.put(id, block);
        return block;
    }

    /// Get block by ID
    pub fn getBlock(self: *const BlockManager, id: []const u8) ?*CommandBlock {
        return self.blocks.get(id);
    }

    /// Get all blocks
    pub fn getAllBlocks(self: *const BlockManager) !ArrayList(*CommandBlock) {
        var result = ArrayList(*CommandBlock).init(self.alloc);
        var iter = self.blocks.iterator();
        while (iter.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }
        return result;
    }

    /// Delete a block
    pub fn deleteBlock(self: *BlockManager, id: []const u8) !void {
        if (self.blocks.fetchRemove(id)) |entry| {
            entry.value.deinit(self.alloc);
            self.alloc.destroy(entry.value);
        }
    }

    /// Create block from AI response (extract commands)
    pub fn createBlockFromResponse(self: *BlockManager, response: []const u8, title: []const u8) !*CommandBlock {
        const block = try self.createBlock(title);

        // Extract commands from markdown code blocks
        var i: usize = 0;
        while (i < response.len) {
            // Look for ``` or `code` blocks
            if (i + 3 <= response.len and std.mem.eql(u8, response[i .. i + 3], "```")) {
                const code_start = i + 3;
                // Skip language identifier
                var actual_start = code_start;
                while (actual_start < response.len and response[actual_start] != '\n') {
                    actual_start += 1;
                }
                if (actual_start < response.len) actual_start += 1; // Skip newline

                // Find closing ```
                if (std.mem.indexOfPos(u8, response, actual_start, "```")) |end| {
                    const code = std.mem.trim(u8, response[actual_start..end], " \t\n\r");
                    if (code.len > 0) {
                        // Split by lines and add each as a command
                        var lines = std.mem.splitScalar(u8, code, '\n');
                        while (lines.next()) |line| {
                            const trimmed = std.mem.trim(u8, line, " \t\r");
                            if (trimmed.len > 0) {
                                try block.addCommand(self.alloc, trimmed);
                            }
                        }
                    }
                    i = end + 3;
                    continue;
                }
            } else if (i < response.len and response[i] == '`') {
                // Inline code block
                if (std.mem.indexOfPos(u8, response, i + 1, "`")) |end| {
                    const code = std.mem.trim(u8, response[i + 1 .. end], " \t\n\r");
                    if (code.len > 0 and !std.mem.containsAtLeast(u8, code, 1, " ")) {
                        // Single command (no spaces = likely a command)
                        try block.addCommand(self.alloc, code);
                    }
                    i = end + 1;
                    continue;
                }
            }
            i += 1;
        }

        return block;
    }

    /// Group commands into blocks based on context
    pub fn groupCommandsIntoBlocks(
        self: *BlockManager,
        commands: []const []const u8,
    ) !ArrayList(*CommandBlock) {
        var blocks = ArrayList(*CommandBlock).init(self.alloc);
        errdefer {
            for (blocks.items) |b| {
                b.deinit(self.alloc);
                self.alloc.destroy(b);
            }
            blocks.deinit();
        }

        // Simple grouping: create blocks based on command prefixes
        var current_block: ?*CommandBlock = null;

        for (commands) |cmd| {
            const prefix = self.getCommandPrefix(cmd);

            // Start new block if prefix changes
            if (current_block == null or !std.mem.eql(u8, prefix, self.getCommandPrefix(current_block.?.commands.items[0]))) {
                if (current_block) |block| {
                    try blocks.append(block);
                }
                const block_title = try std.fmt.allocPrint(self.alloc, "{s} commands", .{prefix});
                current_block = try self.createBlock(block_title);
                self.alloc.free(block_title);
            }

            try current_block.?.addCommand(self.alloc, cmd);
        }

        if (current_block) |block| {
            try blocks.append(block);
        }

        return blocks;
    }

    /// Get command prefix (first word)
    fn getCommandPrefix(self: *const BlockManager, command: []const u8) []const u8 {
        _ = self;
        if (std.mem.indexOfScalar(u8, command, ' ')) |space_idx| {
            return command[0..space_idx];
        }
        return command;
    }
};
