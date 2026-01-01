//! Multi-turn Conversations Module
//!
//! This module provides contextual dialogue history for multi-turn conversations
//! with the AI assistant.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.ai_multi_turn);

/// A conversation turn
pub const ConversationTurn = struct {
    role: Role,
    content: []const u8,
    timestamp: i64,
    context_snapshot: ?[]const u8,

    pub const Role = enum {
        user,
        assistant,
        system,
    };

    pub fn deinit(self: *const ConversationTurn, alloc: Allocator) void {
        alloc.free(self.content);
        if (self.context_snapshot) |ctx| alloc.free(ctx);
    }
};

/// Multi-turn conversation manager
pub const MultiTurnConversation = struct {
    alloc: Allocator,
    turns: ArrayList(ConversationTurn),
    max_turns: usize,
    context_window: usize, // Max context size in characters

    /// Initialize multi-turn conversation
    pub fn init(alloc: Allocator, max_turns: usize, context_window: usize) MultiTurnConversation {
        return .{
            .alloc = alloc,
            .turns = ArrayList(ConversationTurn).init(alloc),
            .max_turns = max_turns,
            .context_window = context_window,
        };
    }

    pub fn deinit(self: *MultiTurnConversation) void {
        for (self.turns.items) |*turn| turn.deinit(self.alloc);
        self.turns.deinit();
    }

    /// Add a turn to the conversation
    pub fn addTurn(
        self: *MultiTurnConversation,
        role: ConversationTurn.Role,
        content: []const u8,
        context_snapshot: ?[]const u8,
    ) !void {
        // Remove old turns if we exceed max
        while (self.turns.items.len >= self.max_turns) {
            const removed = self.turns.orderedRemove(0);
            removed.deinit(self.alloc);
        }

        try self.turns.append(.{
            .role = role,
            .content = try self.alloc.dupe(u8, content),
            .timestamp = std.time.timestamp(),
            .context_snapshot = if (context_snapshot) |ctx| try self.alloc.dupe(u8, ctx) else null,
        });
    }

    /// Build context from conversation history
    pub fn buildContext(self: *const MultiTurnConversation) ![]const u8 {
        var buf = ArrayList(u8).init(self.alloc);
        errdefer buf.deinit();

        var total_size: usize = 0;

        // Add turns in reverse (most recent first) until we hit context limit
        var i: usize = self.turns.items.len;
        while (i > 0) {
            i -= 1;
            const turn = self.turns.items[i];
            const turn_size = turn.content.len + 20; // Approximate size

            if (total_size + turn_size > self.context_window and i > 0) {
                break;
            }

            if (i < self.turns.items.len - 1) {
                try buf.appendSlice("\n\n");
            }

            try buf.writer().print("{s}: {s}", .{ @tagName(turn.role), turn.content });
            total_size += turn_size;
        }

        return buf.toOwnedSlice();
    }

    /// Get recent turns
    pub fn getRecentTurns(self: *const MultiTurnConversation, count: usize) []const ConversationTurn {
        const start = if (self.turns.items.len > count)
            self.turns.items.len - count
        else
            0;
        return self.turns.items[start..];
    }

    /// Clear conversation history
    pub fn clear(self: *MultiTurnConversation) void {
        for (self.turns.items) |*turn| turn.deinit(self.alloc);
        self.turns.clearRetainingCapacity();
    }
};
