//! Command Validation Module
//!
//! This module provides pre-execution safety checks for commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.ai_validation);

/// Validation result
pub const ValidationResult = struct {
    valid: bool,
    warnings: ArrayList([]const u8),
    errors: ArrayList([]const u8),
    risk_level: RiskLevel,

    pub const RiskLevel = enum {
        safe,
        low,
        medium,
        high,
        dangerous,
    };

    pub fn init(alloc: Allocator) ValidationResult {
        return .{
            .valid = true,
            .warnings = ArrayList([]const u8).init(alloc),
            .errors = ArrayList([]const u8).init(alloc),
            .risk_level = .safe,
        };
    }

    pub fn deinit(self: *ValidationResult, alloc: Allocator) void {
        for (self.warnings.items) |w| alloc.free(w);
        self.warnings.deinit();
        for (self.errors.items) |e| alloc.free(e);
        self.errors.deinit();
    }
};

/// Command Validator
pub const CommandValidator = struct {
    alloc: Allocator,
    enabled: bool,
    allow_dangerous: bool,

    /// Initialize command validator
    pub fn init(alloc: Allocator) CommandValidator {
        return .{
            .alloc = alloc,
            .enabled = true,
            .allow_dangerous = false,
        };
    }

    /// Validate a command
    pub fn validate(self: *const CommandValidator, command: []const u8) !ValidationResult {
        var result = ValidationResult.init(self.alloc);
        errdefer result.deinit();

        if (!self.enabled) {
            result.valid = true;
            return result;
        }

        // Check for dangerous patterns
        const dangerous_patterns = [_]struct {
            pattern: []const u8,
            risk: ValidationResult.RiskLevel,
            message: []const u8,
        }{
            .{ .pattern = "rm -rf /", .risk = .dangerous, .message = "Dangerous: Removing root filesystem" },
            .{ .pattern = "rm -rf ~", .risk = .dangerous, .message = "Dangerous: Removing home directory" },
            .{ .pattern = "dd if=", .risk = .high, .message = "High risk: Disk operations" },
            .{ .pattern = "mkfs", .risk = .high, .message = "High risk: Filesystem creation" },
            .{ .pattern = "fdisk", .risk = .high, .message = "High risk: Partition operations" },
            .{ .pattern = "chmod 777", .risk = .medium, .message = "Warning: Overly permissive permissions" },
            .{ .pattern = "sudo rm", .risk = .medium, .message = "Warning: Elevated deletion" },
            .{ .pattern = "> /dev/sd", .risk = .high, .message = "High risk: Writing to block device" },
        };

        for (dangerous_patterns) |danger| {
            if (std.mem.indexOf(u8, command, danger.pattern)) |_| {
                if (@intFromEnum(danger.risk) > @intFromEnum(result.risk_level)) {
                    result.risk_level = danger.risk;
                }

                if (danger.risk == .dangerous) {
                    try result.errors.append(try self.alloc.dupe(u8, danger.message));
                    result.valid = false;
                } else {
                    try result.warnings.append(try self.alloc.dupe(u8, danger.message));
                }
            }
        }

        // Check for sudo usage
        if (std.mem.startsWith(u8, command, "sudo ")) {
            if (@intFromEnum(ValidationResult.RiskLevel.medium) > @intFromEnum(result.risk_level)) {
                result.risk_level = .medium;
            }
            try result.warnings.append(try self.alloc.dupe(u8, "Warning: Command requires elevated privileges"));
        }

        // Check for network operations
        if (std.mem.indexOf(u8, command, "curl") != null or
            std.mem.indexOf(u8, command, "wget") != null)
        {
            if (@intFromEnum(ValidationResult.RiskLevel.low) > @intFromEnum(result.risk_level)) {
                result.risk_level = .low;
            }
        }

        // Block dangerous commands if not allowed
        if (result.risk_level == .dangerous and !self.allow_dangerous) {
            result.valid = false;
        }

        return result;
    }

    /// Enable or disable validation
    pub fn setEnabled(self: *CommandValidator, enabled: bool) void {
        self.enabled = enabled;
    }

    /// Allow dangerous commands
    pub fn setAllowDangerous(self: *CommandValidator, allow: bool) void {
        self.allow_dangerous = allow;
    }
};
