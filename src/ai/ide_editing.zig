//! IDE-like Input Editing Module
//!
//! This module provides advanced text editing features similar to modern IDEs,
//! including multi-cursor support, advanced selection modes, and code formatting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.ai_ide_editing);

/// Cursor position in text
pub const Cursor = struct {
    line: usize,
    column: usize,
    offset: usize, // Character offset from start
};

/// Text selection range
pub const Selection = struct {
    start: Cursor,
    end: Cursor,
    text: []const u8,
};

/// Multi-cursor editing state
pub const MultiCursorState = struct {
    cursors: ArrayList(Cursor),
    primary_cursor: usize, // Index of primary cursor
    selections: ArrayList(Selection),

    pub fn init(alloc: Allocator) MultiCursorState {
        return .{
            .cursors = ArrayList(Cursor).init(alloc),
            .primary_cursor = 0,
            .selections = ArrayList(Selection).init(alloc),
        };
    }

    pub fn deinit(self: *MultiCursorState, alloc: Allocator) void {
        for (self.selections.items) |*sel| {
            alloc.free(sel.text);
        }
        self.cursors.deinit();
        self.selections.deinit();
    }

    /// Add a cursor
    pub fn addCursor(self: *MultiCursorState, cursor: Cursor) !void {
        try self.cursors.append(cursor);
    }

    /// Remove a cursor
    pub fn removeCursor(self: *MultiCursorState, index: usize) void {
        _ = self.cursors.swapRemove(index);
        if (self.primary_cursor >= index and self.primary_cursor > 0) {
            self.primary_cursor -= 1;
        }
    }

    /// Set primary cursor
    pub fn setPrimaryCursor(self: *MultiCursorState, index: usize) void {
        if (index < self.cursors.items.len) {
            self.primary_cursor = index;
        }
    }

    /// Add selection
    pub fn addSelection(self: *MultiCursorState, selection: Selection) !void {
        try self.selections.append(selection);
    }

    /// Clear all cursors except primary
    pub fn clearSecondaryCursors(self: *MultiCursorState) void {
        if (self.cursors.items.len > 1) {
            const primary = self.cursors.items[self.primary_cursor];
            self.cursors.clearRetainingCapacity();
            self.cursors.append(primary) catch {};
            self.primary_cursor = 0;
        }
    }
};

/// IDE Editing Service
pub const IdeEditingService = struct {
    alloc: Allocator,
    multi_cursor: MultiCursorState,
    enabled: bool,

    /// Initialize IDE editing service
    pub fn init(alloc: Allocator) IdeEditingService {
        return .{
            .alloc = alloc,
            .multi_cursor = MultiCursorState.init(alloc),
            .enabled = true,
        };
    }

    pub fn deinit(self: *IdeEditingService) void {
        self.multi_cursor.deinit(self.alloc);
    }

    /// Enable or disable IDE editing features
    pub fn setEnabled(self: *IdeEditingService, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Add cursor at next occurrence of word
    pub fn addCursorAtNextOccurrence(
        self: *IdeEditingService,
        text: []const u8,
        word: []const u8,
        from_offset: usize,
    ) !?Cursor {
        if (from_offset >= text.len) return null;

        const search_text = text[from_offset..];
        if (std.mem.indexOf(u8, search_text, word)) |idx| {
            const offset = from_offset + idx;
            const cursor = try self.offsetToCursor(text, offset);
            return cursor;
        }

        return null;
    }

    /// Select all occurrences of word
    pub fn selectAllOccurrences(
        self: *IdeEditingService,
        text: []const u8,
        word: []const u8,
    ) !ArrayList(Selection) {
        var selections = ArrayList(Selection).init(self.alloc);
        errdefer {
            for (selections.items) |*sel| self.alloc.free(sel.text);
            selections.deinit();
        }

        var offset: usize = 0;
        while (offset < text.len) {
            if (std.mem.indexOfPos(u8, text, offset, word)) |idx| {
                const start_cursor = try self.offsetToCursor(text, idx);
                const end_cursor = try self.offsetToCursor(text, idx + word.len);
                const selected_text = try self.alloc.dupe(u8, word);

                try selections.append(.{
                    .start = start_cursor,
                    .end = end_cursor,
                    .text = selected_text,
                });

                offset = idx + word.len;
            } else {
                break;
            }
        }

        return selections;
    }

    /// Convert character offset to cursor (line, column)
    fn offsetToCursor(self: *IdeEditingService, text: []const u8, offset: usize) !Cursor {
        _ = self;
        var line: usize = 0;
        var column: usize = 0;
        var current_offset: usize = 0;

        for (text, 0..) |ch, i| {
            if (i >= offset) break;
            if (ch == '\n') {
                line += 1;
                column = 0;
            } else {
                column += 1;
            }
            current_offset += 1;
        }

        return Cursor{
            .line = line,
            .column = column,
            .offset = offset,
        };
    }

    /// Format code (basic indentation)
    pub fn formatCode(
        self: *IdeEditingService,
        text: []const u8,
        language: []const u8,
    ) ![]const u8 {
        _ = language; // Would use language-specific formatter

        // Basic indentation formatting
        var result = ArrayList(u8).init(self.alloc);
        errdefer result.deinit();

        var indent_level: usize = 0;
        const indent_size = 2;

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " \t");

            // Decrease indent for closing braces
            if (std.mem.startsWith(u8, trimmed, "}") or std.mem.startsWith(u8, trimmed, "]")) {
                if (indent_level > 0) indent_level -= 1;
            }

            // Add indentation
            for (0..indent_level * indent_size) |_| {
                try result.append(' ');
            }
            try result.appendSlice(trimmed);
            try result.append('\n');

            // Increase indent for opening braces
            if (std.mem.endsWith(u8, trimmed, "{") or std.mem.endsWith(u8, trimmed, "[")) {
                indent_level += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// Duplicate line
    pub fn duplicateLine(
        self: *IdeEditingService,
        text: []const u8,
        line_number: usize,
    ) ![]const u8 {
        var lines = ArrayList([]const u8).init(self.alloc);
        defer {
            for (lines.items) |l| self.alloc.free(l);
            lines.deinit();
        }

        var line_iter = std.mem.splitScalar(u8, text, '\n');
        var current_line: usize = 0;

        while (line_iter.next()) |line| {
            const line_copy = try self.alloc.dupe(u8, line);
            try lines.append(line_copy);

            if (current_line == line_number) {
                // Duplicate this line
                const dup_copy = try self.alloc.dupe(u8, line);
                try lines.append(dup_copy);
            }

            current_line += 1;
        }

        // Reconstruct text
        var result = ArrayList(u8).init(self.alloc);
        errdefer result.deinit();

        for (lines.items, 0..) |line, i| {
            if (i > 0) try result.append('\n');
            try result.appendSlice(line);
        }

        return result.toOwnedSlice();
    }

    /// Comment/uncomment line
    pub fn toggleComment(
        self: *IdeEditingService,
        text: []const u8,
        line_number: usize,
        comment_prefix: []const u8,
    ) ![]const u8 {
        var lines = ArrayList([]const u8).init(self.alloc);
        defer {
            for (lines.items) |l| self.alloc.free(l);
            lines.deinit();
        }

        var line_iter = std.mem.splitScalar(u8, text, '\n');
        var current_line: usize = 0;

        while (line_iter.next()) |line| {
            if (current_line == line_number) {
                const trimmed = std.mem.trimLeft(u8, line, " \t");
                if (std.mem.startsWith(u8, trimmed, comment_prefix)) {
                    // Uncomment
                    const uncommented = trimmed[comment_prefix.len..];
                    const line_copy = try self.alloc.dupe(u8, uncommented);
                    try lines.append(line_copy);
                } else {
                    // Comment
                    const commented = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ comment_prefix, line });
                    try lines.append(commented);
                }
            } else {
                const line_copy = try self.alloc.dupe(u8, line);
                try lines.append(line_copy);
            }

            current_line += 1;
        }

        // Reconstruct text
        var result = ArrayList(u8).init(self.alloc);
        errdefer result.deinit();

        for (lines.items, 0..) |line, i| {
            if (i > 0) try result.append('\n');
            try result.appendSlice(line);
        }

        return result.toOwnedSlice();
    }

    /// Move line up/down
    pub fn moveLine(
        self: *IdeEditingService,
        text: []const u8,
        line_number: usize,
        direction: enum { up, down },
    ) ![]const u8 {
        var lines = ArrayList([]const u8).init(self.alloc);
        defer {
            for (lines.items) |l| self.alloc.free(l);
            lines.deinit();
        }

        var line_iter = std.mem.splitScalar(u8, text, '\n');
        while (line_iter.next()) |line| {
            const line_copy = try self.alloc.dupe(u8, line);
            try lines.append(line_copy);
        }

        if (direction == .up) {
            if (line_number > 0) {
                const temp = lines.items[line_number];
                lines.items[line_number] = lines.items[line_number - 1];
                lines.items[line_number - 1] = temp;
            }
        } else {
            if (line_number < lines.items.len - 1) {
                const temp = lines.items[line_number];
                lines.items[line_number] = lines.items[line_number + 1];
                lines.items[line_number + 1] = temp;
            }
        }

        // Reconstruct text
        var result = ArrayList(u8).init(self.alloc);
        errdefer result.deinit();

        for (lines.items, 0..) |line, i| {
            if (i > 0) try result.append('\n');
            try result.appendSlice(line);
        }

        return result.toOwnedSlice();
    }
};
