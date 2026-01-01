//! Analytics Module
//!
//! This module provides usage tracking and insights for AI features.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_analytics);

/// Analytics event
pub const AnalyticsEvent = struct {
    event_type: EventType,
    timestamp: i64,
    metadata: StringHashMap([]const u8),

    pub const EventType = enum {
        ai_request,
        command_executed,
        workflow_run,
        suggestion_accepted,
        correction_applied,
        error_occurred,
    };

    pub fn deinit(self: *AnalyticsEvent, alloc: Allocator) void {
        var iter = self.metadata.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Analytics Manager
pub const AnalyticsManager = struct {
    alloc: Allocator,
    events: ArrayList(AnalyticsEvent),
    enabled: bool,
    max_events: usize,

    /// Initialize analytics manager
    pub fn init(alloc: Allocator, max_events: usize) AnalyticsManager {
        return .{
            .alloc = alloc,
            .events = ArrayList(AnalyticsEvent).init(alloc),
            .enabled = true,
            .max_events = max_events,
        };
    }

    pub fn deinit(self: *AnalyticsManager) void {
        for (self.events.items) |*event| event.deinit(self.alloc);
        self.events.deinit();
    }

    /// Record an event
    pub fn recordEvent(
        self: *AnalyticsManager,
        event_type: AnalyticsEvent.EventType,
        metadata: ?StringHashMap([]const u8),
    ) !void {
        if (!self.enabled) return;

        const event = AnalyticsEvent{
            .event_type = event_type,
            .timestamp = std.time.timestamp(),
            .metadata = if (metadata) |m| m else StringHashMap([]const u8).init(self.alloc),
        };

        try self.events.append(event);

        // Limit event history
        while (self.events.items.len > self.max_events) {
            const removed = self.events.orderedRemove(0);
            removed.deinit(self.alloc);
        }
    }

    /// Get usage statistics
    pub fn getStats(self: *const AnalyticsManager) struct {
        total_requests: usize,
        total_commands: usize,
        total_workflows: usize,
        error_rate: f64,
        most_used_feature: ?AnalyticsEvent.EventType,
    } {
        var stats = struct {
            total_requests: usize,
            total_commands: usize,
            total_workflows: usize,
            error_rate: f64,
            most_used_feature: ?AnalyticsEvent.EventType,
        }{
            .total_requests = 0,
            .total_commands = 0,
            .total_workflows = 0,
            .error_rate = 0.0,
            .most_used_feature = null,
        };

        var feature_counts = std.EnumArray(AnalyticsEvent.EventType, u32).initFill(0);
        var error_count: usize = 0;

        for (self.events.items) |event| {
            const current_count = feature_counts.get(event.event_type);
            feature_counts.set(event.event_type, current_count + 1);

            switch (event.event_type) {
                .ai_request => stats.total_requests += 1,
                .command_executed => stats.total_commands += 1,
                .workflow_run => stats.total_workflows += 1,
                .error_occurred => error_count += 1,
                else => {},
            }
        }

        if (self.events.items.len > 0) {
            stats.error_rate = @as(f64, @floatFromInt(error_count)) / @as(f64, @floatFromInt(self.events.items.len));
        }

        // Find most used feature
        var max_count: u32 = 0;
        for (std.meta.tags(AnalyticsEvent.EventType)) |event_type| {
            const count = feature_counts.get(event_type);
            if (count > max_count) {
                max_count = count;
                stats.most_used_feature = event_type;
            }
        }

        return stats;
    }

    /// Enable or disable analytics
    pub fn setEnabled(self: *AnalyticsManager, enabled: bool) void {
        self.enabled = enabled;
    }
};
