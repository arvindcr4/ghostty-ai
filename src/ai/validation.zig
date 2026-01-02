//! Command Validation Module
//!
//! This module provides pre-execution safety checks for commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const log = std.log.scoped(.ai_validation);

/// Validation result
pub const ValidationResult = struct {
    valid: bool,
    warnings: ArrayListUnmanaged([]const u8),
    errors: ArrayListUnmanaged([]const u8),
    risk_level: RiskLevel,
    alloc: Allocator,

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
            .warnings = .empty,
            .errors = .empty,
            .risk_level = .safe,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *ValidationResult) void {
        for (self.warnings.items) |w| self.alloc.free(w);
        self.warnings.deinit(self.alloc);
        for (self.errors.items) |e| self.alloc.free(e);
        self.errors.deinit(self.alloc);
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
                    try result.errors.append(self.alloc, try self.alloc.dupe(u8, danger.message));
                    // Only mark as invalid if dangerous commands are not allowed
                    if (!self.allow_dangerous) {
                        result.valid = false;
                    }
                } else {
                    try result.warnings.append(self.alloc, try self.alloc.dupe(u8, danger.message));
                }
            }
        }

        // Check for sudo usage
        if (std.mem.startsWith(u8, command, "sudo ")) {
            if (@intFromEnum(ValidationResult.RiskLevel.medium) > @intFromEnum(result.risk_level)) {
                result.risk_level = .medium;
            }
            try result.warnings.append(self.alloc, try self.alloc.dupe(u8, "Warning: Command requires elevated privileges"));
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

// ============================================================================
// Unit Tests
// ============================================================================

test "ValidationResult initialization" {
    const alloc = std.testing.allocator;

    var result = ValidationResult.init(alloc);
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.safe, result.risk_level);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
}

test "ValidationResult deinit cleanup" {
    const alloc = std.testing.allocator;

    var result = ValidationResult.init(alloc);

    // Add some warnings and errors
    try result.warnings.append(alloc, try alloc.dupe(u8, "test warning"));
    try result.errors.append(alloc, try alloc.dupe(u8, "test error"));

    result.deinit();
    // If we reach here without memory leaks, cleanup worked
}

test "RiskLevel enum values and ordering" {
    try std.testing.expectEqual(@as(usize, 0), @intFromEnum(ValidationResult.RiskLevel.safe));
    try std.testing.expectEqual(@as(usize, 1), @intFromEnum(ValidationResult.RiskLevel.low));
    try std.testing.expectEqual(@as(usize, 2), @intFromEnum(ValidationResult.RiskLevel.medium));
    try std.testing.expectEqual(@as(usize, 3), @intFromEnum(ValidationResult.RiskLevel.high));
    try std.testing.expectEqual(@as(usize, 4), @intFromEnum(ValidationResult.RiskLevel.dangerous));

    // Test ordering comparisons
    try std.testing.expect(@intFromEnum(ValidationResult.RiskLevel.safe) < @intFromEnum(ValidationResult.RiskLevel.low));
    try std.testing.expect(@intFromEnum(ValidationResult.RiskLevel.low) < @intFromEnum(ValidationResult.RiskLevel.medium));
    try std.testing.expect(@intFromEnum(ValidationResult.RiskLevel.medium) < @intFromEnum(ValidationResult.RiskLevel.high));
    try std.testing.expect(@intFromEnum(ValidationResult.RiskLevel.high) < @intFromEnum(ValidationResult.RiskLevel.dangerous));
}

test "CommandValidator initialization" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);
    try std.testing.expect(validator.enabled);
    try std.testing.expect(!validator.allow_dangerous);
}

test "Safe command validation" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    const safe_commands = [_][]const u8{
        "ls -la",
        "cd /home",
        "echo hello world",
        "pwd",
        "whoami",
        "date",
        "cat file.txt",
        "grep pattern file",
    };

    for (safe_commands) |cmd| {
        var result = try validator.validate(cmd);
        defer result.deinit();

        try std.testing.expect(result.valid);
        try std.testing.expectEqual(ValidationResult.RiskLevel.safe, result.risk_level);
        try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
    }
}

test "Dangerous command detection - rm -rf root" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("rm -rf /");
    defer result.deinit();

    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.dangerous, result.risk_level);
    try std.testing.expect(result.errors.items.len > 0);
}

test "Dangerous command detection - rm -rf home" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("rm -rf ~");
    defer result.deinit();

    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.dangerous, result.risk_level);
    try std.testing.expect(result.errors.items.len > 0);
}

test "High risk command detection - dd" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("dd if=/dev/zero of=file.img");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.high, result.risk_level);
    try std.testing.expect(result.warnings.items.len > 0);
}

test "High risk command detection - mkfs" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("mkfs.ext4 /dev/sdb1");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.high, result.risk_level);
    try std.testing.expect(result.warnings.items.len > 0);
}

test "High risk command detection - fdisk" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("fdisk /dev/sda");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.high, result.risk_level);
    try std.testing.expect(result.warnings.items.len > 0);
}

test "High risk command detection - write to block device" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("> /dev/sda");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.high, result.risk_level);
    try std.testing.expect(result.warnings.items.len > 0);
}

test "Medium risk command detection - chmod 777" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("chmod 777 file.txt");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.medium, result.risk_level);
    try std.testing.expect(result.warnings.items.len > 0);
}

test "Medium risk command detection - sudo rm" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("sudo rm file.txt");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.medium, result.risk_level);
    try std.testing.expect(result.warnings.items.len >= 2); // Both sudo and elevated deletion
}

test "Low risk network command detection - curl" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("curl http://example.com");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.low, result.risk_level);
}

test "Low risk network command detection - wget" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("wget http://example.com/file.txt");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.low, result.risk_level);
}

test "Sudo command detection" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("sudo apt update");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.medium, result.risk_level);
    try std.testing.expect(result.warnings.items.len > 0);

    // Check for specific sudo warning
    var found_sudo_warning = false;
    for (result.warnings.items) |warning| {
        if (std.mem.indexOf(u8, warning, "elevated privileges") != null) {
            found_sudo_warning = true;
            break;
        }
    }
    try std.testing.expect(found_sudo_warning);
}

test "Disabled validator behavior" {
    const alloc = std.testing.allocator;

    var validator = CommandValidator.init(alloc);
    validator.setEnabled(false);

    // Even dangerous commands should pass when disabled
    var result = try validator.validate("rm -rf /");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.safe, result.risk_level);
    try std.testing.expectEqual(@as(usize, 0), result.warnings.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
}

test "Allow dangerous mode behavior" {
    const alloc = std.testing.allocator;

    var validator = CommandValidator.init(alloc);
    validator.setAllowDangerous(true);

    // Dangerous commands should be marked as valid when allowed
    var result = try validator.validate("rm -rf /");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.dangerous, result.risk_level);
    try std.testing.expect(result.errors.items.len > 0);
}

test "Multiple warnings accumulation" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    // Command that should trigger multiple warnings
    var result = try validator.validate("sudo chmod 777 file.txt");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.medium, result.risk_level);
    try std.testing.expect(result.warnings.items.len >= 2); // sudo + chmod 777
}

test "Risk level escalation" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    // Command with both medium and high risk patterns
    var result = try validator.validate("sudo dd if=/dev/zero of=file.img");
    defer result.deinit();

    // Should escalate to highest risk level (high)
    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.high, result.risk_level);
}

test "CommandValidator enable/disable toggle" {
    const alloc = std.testing.allocator;

    var validator = CommandValidator.init(alloc);

    // Initially enabled
    try std.testing.expect(validator.enabled);

    // Disable
    validator.setEnabled(false);
    try std.testing.expect(!validator.enabled);

    // Re-enable
    validator.setEnabled(true);
    try std.testing.expect(validator.enabled);
}

test "CommandValidator allow dangerous toggle" {
    const alloc = std.testing.allocator;

    var validator = CommandValidator.init(alloc);

    // Initially not allowing dangerous
    try std.testing.expect(!validator.allow_dangerous);

    // Allow dangerous
    validator.setAllowDangerous(true);
    try std.testing.expect(validator.allow_dangerous);

    // Disallow dangerous
    validator.setAllowDangerous(false);
    try std.testing.expect(!validator.allow_dangerous);
}

test "Memory management with multiple validations" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    const commands = [_][]const u8{
        "ls -la",
        "rm -rf /",
        "dd if=/dev/zero",
        "sudo apt update",
        "curl http://example.com",
        "chmod 777 file",
    };

    for (commands) |cmd| {
        var result = try validator.validate(cmd);
        result.deinit();
    }
    // If we reach here without memory leaks, all cleanup worked
}

test "Empty command validation" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.safe, result.risk_level);
}

test "Whitespace only command validation" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    var result = try validator.validate("   ");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.safe, result.risk_level);
}

test "Complex command with multiple risks" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    // Complex command with multiple parts
    var result = try validator.validate("sudo bash -c 'dd if=/dev/zero of=/tmp/test.img && chmod 777 /tmp/test.img'");
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.high, result.risk_level);
    try std.testing.expect(result.warnings.items.len >= 2);
}

test "Multiple dangerous patterns" {
    const alloc = std.testing.allocator;

    const validator = CommandValidator.init(alloc);

    // Command that triggers multiple dangerous patterns
    var result = try validator.validate("rm -rf / && rm -rf ~");
    defer result.deinit();

    try std.testing.expect(!result.valid);
    try std.testing.expectEqual(ValidationResult.RiskLevel.dangerous, result.risk_level);
    try std.testing.expect(result.errors.items.len >= 2);
}
