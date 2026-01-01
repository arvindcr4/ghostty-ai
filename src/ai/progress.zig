//! Progress Indicators Module
//!
//! This module provides visual feedback for long-running operations.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.ai_progress);

/// Progress indicator
pub const ProgressIndicator = struct {
    task_name: []const u8,
    current: usize,
    total: usize,
    status: Status,
    message: []const u8,

    pub const Status = enum {
        pending,
        running,
        completed,
        failed,
        cancelled,
    };

    pub fn deinit(self: *const ProgressIndicator, alloc: Allocator) void {
        alloc.free(self.task_name);
        alloc.free(self.message);
    }

    /// Get progress percentage
    pub fn getPercentage(self: *const ProgressIndicator) f32 {
        if (self.total == 0) return 0.0;
        return (@as(f32, @floatFromInt(self.current)) / @as(f32, @floatFromInt(self.total))) * 100.0;
    }
};

/// Progress Manager
pub const ProgressManager = struct {
    alloc: Allocator,
    indicators: ArrayList(*ProgressIndicator),
    enabled: bool,

    /// Initialize progress manager
    pub fn init(alloc: Allocator) ProgressManager {
        return .{
            .alloc = alloc,
            .indicators = ArrayList(*ProgressIndicator).init(alloc),
            .enabled = true,
        };
    }

    pub fn deinit(self: *ProgressManager) void {
        for (self.indicators.items) |indicator| {
            indicator.deinit(self.alloc);
            self.alloc.destroy(indicator);
        }
        self.indicators.deinit();
    }

    /// Create a progress indicator
    pub fn createIndicator(
        self: *ProgressManager,
        task_name: []const u8,
        total: usize,
    ) !*ProgressIndicator {
        const indicator = try self.alloc.create(ProgressIndicator);
        indicator.* = .{
            .task_name = try self.alloc.dupe(u8, task_name),
            .current = 0,
            .total = total,
            .status = .pending,
            .message = try self.alloc.dupe(u8, "Starting..."),
        };

        try self.indicators.append(indicator);
        return indicator;
    }

    /// Update progress
    pub fn updateProgress(
        self: *const ProgressManager,
        indicator: *ProgressIndicator,
        current: usize,
        message: []const u8,
    ) !void {
        indicator.current = current;
        // Free old message if it exists
        if (indicator.message.len > 0) {
            // Note: In production, would track allocator properly
            // For now, assume message was allocated with self.alloc
        }
        indicator.message = try self.alloc.dupe(u8, message);
        indicator.status = .running;
    }

    /// Mark progress as complete
    pub fn completeProgress(
        _: *const ProgressManager,
        indicator: *ProgressIndicator,
    ) void {
        indicator.status = .completed;
        indicator.current = indicator.total;
    }

    /// Mark progress as failed
    pub fn failProgress(
        self: *const ProgressManager,
        indicator: *ProgressIndicator,
        error_message: []const u8,
    ) !void {
        indicator.status = .failed;
        // Free old message
        if (indicator.message.len > 0) {
            // Note: In production, would track allocator properly
        }
        indicator.message = try self.alloc.dupe(u8, error_message);
    }

    /// Enable or disable progress indicators
    pub fn setEnabled(self: *ProgressManager, enabled: bool) void {
        self.enabled = enabled;
    }
};
