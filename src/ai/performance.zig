//! Performance Optimization Module
//!
//! This module provides caching and optimization for faster AI response times.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_performance);

/// Cache entry for AI responses
const CacheEntry = struct {
    prompt_hash: u64,
    response: []const u8,
    timestamp: i64,
    hit_count: u32,
};

/// Performance Optimizer
pub const PerformanceOptimizer = struct {
    alloc: Allocator,
    response_cache: StringHashMap(CacheEntry),
    max_cache_size: usize,
    cache_ttl_seconds: i64,

    /// Initialize performance optimizer
    pub fn init(alloc: Allocator, max_cache_size: usize, ttl_seconds: i64) PerformanceOptimizer {
        return .{
            .alloc = alloc,
            .response_cache = StringHashMap(CacheEntry).init(alloc),
            .max_cache_size = max_cache_size,
            .ttl_seconds = ttl_seconds,
        };
    }

    pub fn deinit(self: *PerformanceOptimizer) void {
        var iter = self.response_cache.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.value_ptr.response);
        }
        self.response_cache.deinit();
    }

    /// Hash a prompt for caching
    fn hashPrompt(prompt: []const u8) u64 {
        var hasher = std.hash.Fnv1a_64.init();
        hasher.update(prompt);
        return hasher.final();
    }

    /// Get cached response if available
    pub fn getCachedResponse(
        self: *PerformanceOptimizer,
        prompt: []const u8,
    ) ?[]const u8 {
        const hash = hashPrompt(prompt);
        const hash_str = std.fmt.allocPrint(self.alloc, "{d}", .{hash}) catch |err| {
            log.warn("Failed to allocate hash string for cache lookup: {}", .{err});
            return null;
        };
        defer self.alloc.free(hash_str);

        if (self.response_cache.get(hash_str)) |entry| {
            const now = std.time.timestamp();
            if (now - entry.timestamp < self.cache_ttl_seconds) {
                return entry.response;
            } else {
                // Expired, remove
                _ = self.response_cache.remove(hash_str);
            }
        }

        return null;
    }

    /// Cache a response
    pub fn cacheResponse(
        self: *PerformanceOptimizer,
        prompt: []const u8,
        response: []const u8,
    ) !void {
        const hash = hashPrompt(prompt);
        const hash_str = try std.fmt.allocPrint(self.alloc, "{d}", .{hash});

        // Remove old entry if exists
        if (self.response_cache.fetchRemove(hash_str)) |entry| {
            self.alloc.free(entry.value.response);
        }

        // Check cache size
        if (self.response_cache.count() >= self.max_cache_size) {
            // Remove least recently used (simplified - remove oldest)
            var oldest_key: ?[]const u8 = null;
            var oldest_time: i64 = std.math.maxInt(i64);

            var iter = self.response_cache.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.timestamp < oldest_time) {
                    oldest_time = entry.value_ptr.timestamp;
                    oldest_key = entry.key_ptr.*;
                }
            }

            if (oldest_key) |key| {
                if (self.response_cache.fetchRemove(key)) |entry| {
                    self.alloc.free(entry.value.response);
                }
            }
        }

        try self.response_cache.put(hash_str, .{
            .prompt_hash = hash,
            .response = try self.alloc.dupe(u8, response),
            .timestamp = std.time.timestamp(),
            .hit_count = 0,
        });
    }

    /// Clear expired cache entries
    pub fn cleanupCache(self: *PerformanceOptimizer) void {
        const now = std.time.timestamp();
        var keys_to_remove = ArrayList([]const u8).init(self.alloc);
        defer {
            for (keys_to_remove.items) |k| self.alloc.free(k);
            keys_to_remove.deinit();
        }

        var iter = self.response_cache.iterator();
        while (iter.next()) |entry| {
            if (now - entry.value_ptr.timestamp >= self.cache_ttl_seconds) {
                keys_to_remove.append(self.alloc.dupe(u8, entry.key_ptr.*) catch continue) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            if (self.response_cache.fetchRemove(key)) |entry| {
                self.alloc.free(entry.value.response);
            }
            self.alloc.free(key);
        }
    }

    /// Get cache statistics
    pub fn getCacheStats(self: *const PerformanceOptimizer) struct {
        size: usize,
        max_size: usize,
        hit_rate: f64,
    } {
        var total_hits: u32 = 0;
        var iter = self.response_cache.iterator();
        while (iter.next()) |entry| {
            total_hits += entry.value_ptr.hit_count;
        }

        return .{
            .size = self.response_cache.count(),
            .max_size = self.max_cache_size,
            .hit_rate = if (self.response_cache.count() > 0)
                @as(f64, @floatFromInt(total_hits)) / @as(f64, @floatFromInt(self.response_cache.count()))
            else
                0.0,
        };
    }
};
