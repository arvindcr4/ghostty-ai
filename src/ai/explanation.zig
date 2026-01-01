//! AI Command Explanation Service
//!
//! This module provides AI-powered explanations for terminal commands.
//! It maintains a cache of previously explained commands to avoid
//! repeated API calls.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_explanation);

/// Cached command explanation
pub const CachedExplanation = struct {
    explanation: []const u8,
    timestamp: i64,
    hit_count: u32,

    pub fn deinit(self: *const CachedExplanation, alloc: Allocator) void {
        alloc.free(self.explanation);
    }
};

/// AI Command Explanation Service
pub const ExplanationService = struct {
    const Self = @This();

    alloc: Allocator,
    cache: StringHashMap(CachedExplanation),
    cache_max_size: usize,
    cache_ttl_seconds: i64,

    /// Initialize the explanation service
    pub fn init(alloc: Allocator) Self {
        return .{
            .alloc = alloc,
            .cache = StringHashMap(CachedExplanation).init(alloc),
            .cache_max_size = 1000,
            .cache_ttl_seconds = 3600, // 1 hour
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.cache.deinit();
    }

    /// Get explanation for a command
    pub fn explain(
        self: *Self,
        command: []const u8,
        ai_client: anytype,
    ) ![]const u8 {
        const now = std.time.timestamp();

        // Check cache
        if (self.cache.fetchGet(command)) |cached| {
            // Check if cache entry is still valid
            if (now - cached.timestamp < self.cache_ttl_seconds) {
                // Update hit count
                cached.value_ptr.hit_count += 1;
                return cached.value_ptr.explanation;
            } else {
                // Expired, remove from cache
                cached.value_ptr.deinit(self.alloc);
                self.cache.remove(command);
            }
        }

        // Generate new explanation
        const explanation = try self.generateExplanation(command, ai_client);

        // Add to cache
        try self.addToCache(command, explanation);

        return explanation;
    }

    /// Generate explanation using AI
    fn generateExplanation(
        self: *Self,
        command: []const u8,
        ai_client: anytype,
    ) ![]const u8 {
        const prompt = try std.fmt.allocPrint(self.alloc,
            \\Explain this terminal command in 1-2 sentences:
            \\
            \\{s}
            \\
            \\Focus on what the command does and its main flags/options.
            \\Keep it concise and clear for a terminal user.
        , .{command});
        defer self.alloc.free(prompt);

        const response = try ai_client.chat(
            \\You are a terminal command assistant. Explain commands concisely.
        , prompt);

        defer response.deinit(self.alloc);
        return response.content;
    }

    /// Add explanation to cache
    fn addToCache(self: *Self, command: []const u8, explanation: []const u8) !void {
        // Enforce cache size limit
        if (self.cache.count() >= self.cache_max_size) {
            // Evict oldest/least-used entry (simplified: just remove first)
            var iter = self.cache.iterator();
            if (iter.next()) |entry| {
                entry.value_ptr.deinit(self.alloc);
                self.cache.remove(entry.key_ptr.*);
            }
        }

        // Add new entry
        try self.cache.put(command, .{
            .explanation = try self.alloc.dupe(u8, explanation),
            .timestamp = std.time.timestamp(),
            .hit_count = 1,
        });
    }

    /// Clear the cache
    pub fn clearCache(self: *Self) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.cache.clearRetainingCapacity();
    }

    /// Get cache statistics
    pub const CacheStats = struct {
        size: usize,
        total_hits: u32,
    };

    pub fn getStats(self: *const Self) CacheStats {
        var total_hits: u32 = 0;
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            total_hits += entry.value_ptr.hit_count;
        }

        return .{
            .size = self.cache.count(),
            .total_hits = total_hits,
        };
    }
};

/// Parse command from terminal text at cursor position
pub fn parseCommandAtCursor(alloc: Allocator, text: []const u8, cursor_col: usize) ![]const u8 {
    // Find the start of the command (go back from cursor to line start)
    var start = cursor_col;
    while (start > 0 and text[start - 1] != '\n') {
        start -= 1;
    }

    // Find the end of the command (go forward from cursor to line end)
    var end = cursor_col;
    while (end < text.len and text[end] != '\n') {
        end += 1;
    }

    const line = text[start..end];

    // Find the command portion (before pipe, redirection, etc.)
    const cmd_end = blk: {
        if (std.mem.indexOfScalar(u8, line, '|')) |idx| break :blk idx;
        if (std.mem.indexOfScalar(u8, line, '>')) |idx| break :blk idx;
        if (std.mem.indexOfScalar(u8, line, ';')) |idx| break :blk idx;
        if (std.mem.indexOfScalar(u8, line, '&')) |idx| break :blk idx;
        break :blk line.len;
    };

    // Trim leading whitespace and get command
    const trimmed = std.mem.trimLeft(u8, line[0..cmd_end]);
    if (trimmed.len == 0) return error.NoCommandFound;

    // Get just the command name and its arguments
    const cmd_end_final = if (std.mem.indexOfScalar(u8, trimmed, '#')) |idx| idx else trimmed.len;
    const result = std.mem.trimRight(u8, trimmed[0..cmd_end_final]);

    return alloc.dupe(u8, result);
}
