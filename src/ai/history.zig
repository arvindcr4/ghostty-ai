//! AI Conversation History Manager
//!
//! This module provides persistent storage and retrieval of AI conversations,
//! allowing users to search, recall, and continue past conversations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;
const log = std.log.scoped(.ai_history);

/// Single message in a conversation
pub const Message = struct {
    role: Role,
    content: []const u8,
    timestamp: i64,

    pub const Role = enum {
        user,
        assistant,
        system,
    };

    pub fn deinit(self: *const Message, alloc: Allocator) void {
        alloc.free(self.content);
    }
};

/// A conversation with AI
pub const Conversation = struct {
    id: []const u8,
    title: []const u8, // Auto-generated from first user message
    messages: std.ArrayList(Message),
    created_at: i64,
    updated_at: i64,
    tags: std.ArrayList([]const u8),

    pub fn init(alloc: Allocator, id: []const u8) Conversation {
        return .{
            .id = id,
            .title = "",
            .messages = std.ArrayList(Message).init(alloc),
            .created_at = std.time.timestamp(),
            .updated_at = std.time.timestamp(),
            .tags = std.ArrayList([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *const Conversation, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        for (self.messages.items) |msg| msg.deinit(alloc);
        self.messages.deinit();
        for (self.tags.items) |tag| alloc.free(tag);
        self.tags.deinit();
    }

    /// Generate title from first user message
    pub fn generateTitle(self: *Conversation, alloc: Allocator) !void {
        if (self.messages.items.len == 0) return;

        // Find first user message
        for (self.messages.items) |msg| {
            if (msg.role == .user) {
                // Truncate to 50 chars for title
                const max_len = @min(msg.content.len, 50);
                self.title = try alloc.dupe(u8, msg.content[0..max_len]);

                // Add ellipsis if truncated
                if (msg.content.len > 50) {
                    // Need to realloc with ellipsis
                    alloc.free(self.title);
                    self.title = try std.fmt.allocPrint(alloc, "{s}...", .{msg.content[0..47]});
                }
                break;
            }
        }
    }
};

/// History manager for AI conversations
pub const HistoryManager = struct {
    const Self = @This();

    alloc: Allocator,
    history_dir: []const u8,
    conversations: std.StringHashMap(*Conversation),
    current_conversation: ?*Conversation = null,

    /// Initialize history manager
    pub fn init(alloc: Allocator) !Self {
        // Get history directory path
        const home = std.os.getenv("HOME") orelse return error.HomeNotSet;
        const history_path = try std.fs.path.join(alloc, &.{ home, ".config", "ghostty", "ai_history" });

        // Create directory if it doesn't exist
        fs.makeDirAbsolute(history_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return Self{
            .alloc = alloc,
            .history_dir = history_path,
            .conversations = std.StringHashMap(*Conversation).init(alloc),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.conversations.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.conversations.deinit();
        self.alloc.free(self.history_dir);
    }

    /// Create a new conversation
    pub fn createConversation(self: *Self) !*Conversation {
        const id = try std.fmt.allocPrint(self.alloc, "{d}", .{std.time.timestamp()});

        const conv = try self.alloc.create(Conversation);
        conv.* = Conversation.init(self.alloc, id);

        try self.conversations.put(id, conv);
        self.current_conversation = conv;

        return conv;
    }

    /// Save conversation to disk
    pub fn saveConversation(self: *Self, conv: *const Conversation) !void {
        const file_path = try std.fs.path.join(self.alloc, &.{ self.history_dir, conv.id });

        const file = try fs.createFileAbsolute(file_path, .{});
        defer file.close();

        const writer = file.writer();

        // Write JSON
        try writer.writeAll("{\"id\":\"");
        try std.json.escapeString(conv.id, writer);
        try writer.writeAll("\",\"title\":\"");
        try std.json.escapeString(conv.title, writer);
        try writer.writeAll("\",\"created_at\":");
        try writer.print("{d}", .{conv.created_at});
        try writer.writeAll(",\"updated_at\":");
        try writer.print("{d}", .{conv.updated_at});
        try writer.writeAll(",\"messages\":[");

        for (conv.messages.items, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"role\":\"{s}\",\"content\":\"", .{@tagName(msg.role)});
            try std.json.escapeString(msg.content, writer);
            try writer.print("\",\"timestamp\":{d}}", .{msg.timestamp});
        }

        try writer.writeAll("],\"tags\":[");

        for (conv.tags.items, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{tag});
        }

        try writer.writeAll("]}");
    }

    /// Load conversation from disk
    pub fn loadConversation(self: *Self, id: []const u8) !*Conversation {
        const file_path = try std.fs.path.join(self.alloc, &.{ self.history_dir, id });

        const file = try fs.openFileAbsolute(file_path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.alloc, 1_000_000);
        defer self.alloc.free(content);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, content);
        defer parsed.deinit();

        const obj = parsed.object;

        const conv = try self.alloc.create(Conversation);
        errdefer self.alloc.destroy(conv);

        conv.* = Conversation.init(
            self.alloc,
            try self.alloc.dupe(u8, obj.get("id").?.string orelse return error.MissingId),
        );

        if (obj.get("title")) |title_val| {
            conv.title = try self.alloc.dupe(u8, title_val.string);
        }

        if (obj.get("created_at")) |val| {
            conv.created_at = @intCast(val.integer);
        }

        if (obj.get("updated_at")) |val| {
            conv.updated_at = @intCast(val.integer);
        }

        // Load messages
        if (obj.get("messages")) |messages_val| {
            for (messages_val.array.items) |msg_val| {
                const msg_obj = msg_val.object;
                const role_str = msg_obj.get("role").?.string orelse continue;
                const role = std.meta.stringToEnum(Message.Role, role_str) orelse continue;

                try conv.messages.append(.{
                    .role = role,
                    .content = try self.alloc.dupe(u8, msg_obj.get("content").?.string orelse ""),
                    .timestamp = @intCast(msg_obj.get("timestamp").?.integer orelse std.time.timestamp()),
                });
            }
        }

        // Load tags
        if (obj.get("tags")) |tags_val| {
            for (tags_val.array.items) |tag_val| {
                try conv.tags.append(try self.alloc.dupe(u8, tag_val.string));
            }
        }

        try self.conversations.put(conv.id, conv);
        return conv;
    }

    /// Search conversations by query
    pub fn search(self: *Self, query: []const u8) !std.ArrayList(*Conversation) {
        var results = std.ArrayList(*Conversation).init(self.alloc);

        var iter = self.conversations.iterator();
        while (iter.next()) |entry| {
            const conv = entry.value_ptr.*;

            // Search in title and messages
            var found = false;

            // Check title
            if (std.mem.indexOf(u8, conv.title, query) != null) {
                found = true;
            }

            // Check messages
            if (!found) {
                for (conv.messages.items) |msg| {
                    if (std.mem.indexOf(u8, msg.content, query) != null) {
                        found = true;
                        break;
                    }
                }
            }

            if (found) {
                try results.append(conv);
            }
        }

        return results;
    }

    /// Get recent conversations
    pub fn getRecent(self: *Self, limit: usize) !std.ArrayList(*Conversation) {
        var results = std.ArrayList(*Conversation).init(self.alloc);

        var iter = self.conversations.iterator();
        while (iter.next()) |entry| {
            try results.append(entry.value_ptr.*);
        }

        // Sort by updated_at (newest first)
        std.sort.insertion(*Conversation, results.items, {}, struct {
            fn compare(_: void, a: *Conversation, b: *Conversation) bool {
                return a.updated_at > b.updated_at;
            }
        }.compare);

        // Limit results
        if (results.items.len > limit) {
            results.shrinkRetainingCapacity(limit);
        }

        return results;
    }

    /// Load all conversations from disk
    pub fn loadAll(self: *Self) !void {
        const dir = try fs.openDirAbsolute(self.history_dir, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                // Extract ID from filename (remove .json if present)
                const id = if (std.mem.endsWith(u8, entry.name, ".json"))
                    try self.alloc.dupe(u8, entry.name[0 .. entry.name.len - 5])
                else
                    try self.alloc.dupe(u8, entry.name);

                _ = self.loadConversation(id) catch |err| {
                    log.warn("Failed to load conversation {s}: {}", .{id, err});
                    self.alloc.free(id);
                };
            }
        }
    }

    /// Delete a conversation
    pub fn deleteConversation(self: *Self, id: []const u8) !void {
        // Remove from memory
        if (self.conversations.fetchRemove(id)) |entry| {
            entry.value.deinit(self.alloc);
        }

        // Remove from disk
        const file_path = try std.fs.path.join(self.alloc, &.{ self.history_dir, id });
        fs.deleteFileAbsolute(file_path) catch |err| {
            log.warn("Failed to delete conversation file: {}", .{err});
        };
    }
};
