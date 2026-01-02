//! Error Recovery Module
//!
//! This module provides graceful handling of failures and error recovery.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.ai_error_recovery);

/// Error recovery strategy
pub const RecoveryStrategy = struct {
    strategy_type: StrategyType,
    max_retries: u32,
    retry_delay_ms: u64,
    fallback_action: ?[]const u8,

    /// Type of recovery action to take
    pub const StrategyType = enum {
        /// Retry the failed operation
        retry,
        /// Use an alternative fallback action
        fallback,
        /// Skip the failed operation and continue
        skip,
        /// Stop execution entirely
        abort,
    };

    /// Free allocated resources
    pub fn deinit(self: *const RecoveryStrategy, alloc: Allocator) void {
        if (self.fallback_action) |action| alloc.free(action);
    }
};

/// Error Recovery Manager
pub const ErrorRecoveryManager = struct {
    alloc: Allocator,
    strategies: ArrayList(RecoveryStrategy),
    enabled: bool,

    /// Initialize error recovery manager
    pub fn init(alloc: Allocator) ErrorRecoveryManager {
        var manager = ErrorRecoveryManager{
            .alloc = alloc,
            .strategies = ArrayList(RecoveryStrategy).init(alloc),
            .enabled = true,
        };

        // Register default strategies
        manager.registerDefaultStrategies() catch {};

        return manager;
    }

    /// Clean up all registered strategies
    pub fn deinit(self: *ErrorRecoveryManager) void {
        for (self.strategies.items) |*strategy| strategy.deinit(self.alloc);
        self.strategies.deinit();
    }

    /// Register default recovery strategies
    fn registerDefaultStrategies(self: *ErrorRecoveryManager) !void {
        // Network error - retry with exponential backoff
        try self.strategies.append(.{
            .strategy_type = .retry,
            .max_retries = 3,
            .retry_delay_ms = 1000,
            .fallback_action = null,
        });

        // API error - fallback to different provider
        try self.strategies.append(.{
            .strategy_type = .fallback,
            .max_retries = 1,
            .retry_delay_ms = 0,
            .fallback_action = try self.alloc.dupe(u8, "Switch to backup AI provider"),
        });
    }

    /// Handle an error with recovery
    pub fn handleError(
        self: *const ErrorRecoveryManager,
        error_type: ErrorType,
        attempt: u32,
    ) !RecoveryAction {
        if (!self.enabled) return .{ .action = .abort, .message = "Error recovery disabled" };

        const strategy = self.findStrategy(error_type) orelse {
            return .{ .action = .abort, .message = "No recovery strategy found" };
        };

        if (attempt >= strategy.max_retries) {
            return .{
                .action = if (strategy.fallback_action) |_| .fallback else .abort,
                .message = if (strategy.fallback_action) |msg| msg else "Max retries exceeded",
            };
        }

        return .{
            .action = switch (strategy.strategy_type) {
                .retry => .retry,
                .fallback => .fallback,
                .skip => .skip,
                .abort => .abort,
            },
            .message = "Recovery strategy applied",
            .delay_ms = strategy.retry_delay_ms,
        };
    }

    /// Find strategy for error type
    fn findStrategy(
        self: *const ErrorRecoveryManager,
        error_type: ErrorType,
    ) ?RecoveryStrategy {
        _ = error_type;
        if (self.strategies.items.len > 0) {
            return self.strategies.items[0];
        }
        return null;
    }

    pub const ErrorType = enum {
        network_error,
        api_error,
        timeout_error,
        parse_error,
        unknown_error,
    };

    pub const RecoveryAction = struct {
        action: Action,
        message: []const u8 = "",
        delay_ms: u64 = 0,

        pub const Action = enum {
            retry,
            fallback,
            skip,
            abort,
        };
    };
};
