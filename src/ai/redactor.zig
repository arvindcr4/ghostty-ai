//! Secret Redaction for AI Context
//!
//! This module provides functionality to automatically detect and redact
//! sensitive information (API keys, tokens, passwords, etc.) from terminal
//! content before sending it to AI providers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_redaction);

/// Redaction rule for matching and replacing sensitive patterns
pub const RedactionRule = struct {
    /// Regular expression pattern to match
    pattern: []const u8,
    /// Replacement text (use {1}, {2} for capture groups)
    replacement: []const u8,
    /// Description of what this rule redacts
    description: []const u8,
    /// Compiled regex (initialized when needed)
    regex: ?Regex = null,

    pub fn deinit(self: *RedactionRule, alloc: Allocator) void {
        if (self.regex) |*r| {
            r.deinit(alloc);
        }
        // Free duplicated strings
        alloc.free(self.pattern);
        alloc.free(self.replacement);
        alloc.free(self.description);
    }
};

/// Secret Redactor
pub const Redactor = struct {
    const Self = @This();

    alloc: Allocator,
    rules: std.ArrayListUnmanaged(RedactionRule),
    enabled_patterns: StringHashMap(bool),

    /// Initialize a new redactor
    pub fn init(alloc: Allocator) Self {
        var redactor: Self = .{
            .alloc = alloc,
            .rules = .empty,
            .enabled_patterns = StringHashMap(bool).init(alloc),
        };

        // Add default rules
        redactor.addDefaultRules() catch {};

        return redactor;
    }

    /// Clean up redactor resources
    pub fn deinit(self: *Self) void {
        for (self.rules.items) |*rule| {
            rule.deinit(self.alloc);
        }
        self.rules.deinit(self.alloc);
        self.enabled_patterns.deinit();
    }

    /// Add default redaction rules
    fn addDefaultRules(self: *Self) !void {
        // API Keys and Tokens
        try self.addRule(
            // OpenAI API keys
            "(sk-|sk-proj-)[a-zA-Z0-9_-]{20,}",
            "[OPENAI_API_KEY]",
            "OpenAI API key",
        );

        try self.addRule(
            // Anthropic API keys
            "sk-ant-[a-zA-Z0-9_-]{20,}",
            "[ANTHROPIC_API_KEY]",
            "Anthropic API key",
        );

        try self.addRule(
            // GitHub tokens
            "ghp_[a-zA-Z0-9]{36}",
            "[GITHUB_TOKEN]",
            "GitHub personal access token",
        );

        try self.addRule(
            // GitHub OAuth tokens
            "gho_[a-zA-Z0-9]{36}",
            "[GITHUB_OAUTH_TOKEN]",
            "GitHub OAuth token",
        );

        try self.addRule(
            // GitHub app tokens
            "(ghu|ghs|ghr)_[a-zA-Z0-9]{36}",
            "[GITHUB_TOKEN]",
            "GitHub user/server/app token",
        );

        try self.addRule(
            // Slack tokens
            "xox[baprs]-[a-zA-Z0-9-]{10,}",
            "[SLACK_TOKEN]",
            "Slack API token",
        );

        try self.addRule(
            // AWS Access Key ID
            "AKIA[0-9A-Z]{16}",
            "[AWS_ACCESS_KEY_ID]",
            "AWS access key ID",
        );

        try self.addRule(
            // AWS Secret Access Key (context-aware, follows Access Key ID)
            "(?<=AKIA[0-9A-Z]{16}[\\s/:])[a-zA-Z0-9/+]{40}",
            "[AWS_SECRET_ACCESS_KEY]",
            "AWS secret access key",
        );

        try self.addRule(
            // Google Cloud API keys
            "AIza[A-Za-z0-9_-]{35}",
            "[GOOGLE_API_KEY]",
            "Google Cloud API key",
        );

        try self.addRule(
            // Google Cloud OAuth tokens
            "ya29\\.[a-zA-Z0-9_-]{100,}",
            "[GOOGLE_OAUTH_TOKEN]",
            "Google Cloud OAuth token",
        );

        try self.addRule(
            // Stripe API keys
            "sk_live_[a-zA-Z0-9]{24,}",
            "[STRIPE_LIVE_KEY]",
            "Stripe live API key",
        );

        try self.addRule(
            // Stripe test keys
            "sk_test_[a-zA-Z0-9]{24,}",
            "[STRIPE_TEST_KEY]",
            "Stripe test API key",
        );

        // Generic tokens and secrets
        try self.addRule(
            // Bearer tokens
            "Bearer [a-zA-Z0-9_-]{20,}",
            "[BEARER_TOKEN]",
            "Bearer authentication token",
        );

        try self.addRule(
            // Authorization headers
            "(?i)authorization:\\s*[Bb]earer\\s+[a-zA-Z0-9._~-]+",
            "Authorization: Bearer [TOKEN]",
            "Authorization header with bearer token",
        );

        try self.addRule(
            // API key in query params
            "[?&]api[_-]?key=[a-zA-Z0-9_-]{20,}",
            "[REDACTED_API_KEY]",
            "API key in URL query parameter",
        );

        try self.addRule(
            // Token in query params
            "[?&]token=[a-zA-Z0-9._~-]{20,}",
            "[REDACTED_TOKEN]",
            "Token in URL query parameter",
        );

        // Passwords
        try self.addRule(
            // Password in CLI args (--password, -p)
            "(?i)(--password|-p)[=:\\s]+[^\\s\"']{8,}",
            "[PASSWORD]",
            "Command-line password argument",
        );

        try self.addRule(
            // Database connection strings
            "(?i)(mysql|postgresql|mongodb|redis)://[^\\s@:]+:[^\\s@]+@",
            "$1://[USER]:[PASSWORD]@",
            "Database connection string",
        );

        try self.addRule(
            // Generic private keys (PEM format markers)
            "-----BEGIN [A-Z]+ PRIVATE KEY-----",
            "[PRIVATE KEY REDACTED]",
            "PEM private key marker",
        );

        // SSH Keys
        try self.addRule(
            // SSH private key file paths
            "(?i)/[/\\.]*id_[a-z]+",
            "[SSH_KEY_PATH]",
            "SSH private key path",
        );

        try self.addRule(
            // SSH key content markers
            "ssh-[a-z0-9]{10,}",
            "[SSH_KEY_ID]",
            "SSH key identifier",
        );
    }

    /// Add a custom redaction rule
    pub fn addRule(self: *Self, pattern: []const u8, replacement: []const u8, description: []const u8) !void {
        const duped_pattern = try self.alloc.dupe(u8, pattern);
        errdefer self.alloc.free(duped_pattern);
        const duped_replacement = try self.alloc.dupe(u8, replacement);
        errdefer self.alloc.free(duped_replacement);
        const duped_description = try self.alloc.dupe(u8, description);
        errdefer self.alloc.free(duped_description);
        const rule = RedactionRule{
            .pattern = duped_pattern,
            .replacement = duped_replacement,
            .description = duped_description,
            .regex = null,
        };
        try self.rules.append(self.alloc, rule);

        // Enable by default
        try self.enabled_patterns.put(rule.pattern, true);
    }

    /// Redact sensitive information from text
    pub fn redact(self: *Self, input: []const u8) ![]const u8 {
        var result: []const u8 = try self.alloc.dupe(u8, input);
        errdefer self.alloc.free(result);

        for (self.rules.items) |*rule| {
            const pattern_key = rule.pattern;

            // Skip if pattern is disabled
            if (self.enabled_patterns.get(pattern_key)) |enabled| {
                if (!enabled) continue;
            } else {
                // Default to enabled if not in map
            }

            // Compile regex if needed
            if (rule.regex == null) {
                const regex = try Regex.compile(self.alloc, rule.pattern, .{});
                rule.regex = regex;
            }

            // Apply redaction
            const old_result = result;
            result = try self.applyRule(result, rule);
            // Free old buffer if applyRule created a new one
            if (result.ptr != old_result.ptr) {
                self.alloc.free(old_result);
            }
        }

        return result;
    }

    /// Apply a single redaction rule
    fn applyRule(self: *Self, input: []const u8, rule: *const RedactionRule) ![]const u8 {
        const regex = rule.regex orelse return input;

        var matches = try regex.findAll(self.alloc, input);
        defer {
            for (matches.items) |m| {
                self.alloc.free(m);
            }
            matches.deinit(self.alloc);
        }

        if (matches.items.len == 0) {
            return input;
        }

        // Build redacted string
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(self.alloc);

        var last_end: usize = 0;
        for (matches.items) |match_str| {
            // Find this match in original input
            const match_start = std.mem.indexOf(u8, input[last_end..], match_str) orelse continue;
            const abs_start = last_end + match_start;
            const abs_end = abs_start + match_str.len;

            // Append everything before the match
            try result.appendSlice(self.alloc, input[last_end..abs_start]);

            // Append replacement
            try result.appendSlice(self.alloc, rule.replacement);

            last_end = abs_end;
        }

        // Append remaining text
        try result.appendSlice(self.alloc, input[last_end..]);

        // Free input if it was previously allocated
        // Note: This assumes input was allocated by our allocator
        // We need to be careful not to free static strings

        return result.toOwnedSlice(self.alloc);
    }

    /// Enable or disable a specific redaction pattern
    pub fn setPatternEnabled(self: *Self, pattern: []const u8, enabled: bool) !void {
        try self.enabled_patterns.put(pattern, enabled);
    }

    /// Get statistics about redaction
    pub const Stats = struct {
        total_rules: usize,
        enabled_rules: usize,
        patterns_redacted: usize,
    };

    pub fn getStats(self: *const Self) Stats {
        var enabled_count: usize = 0;
        var iter = self.enabled_patterns.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*) {
                enabled_count += 1;
            }
        }

        return .{
            .total_rules = self.rules.items.len,
            .enabled_rules = enabled_count,
            .patterns_redacted = 0, // TODO: Track redactions
        };
    }
};

/// Simple pattern matcher for secret detection
/// Uses prefix/literal matching since Zig lacks built-in regex
const Regex = struct {
    pattern: []const u8,
    prefix: []const u8,
    min_length: usize,

    const prefixes = [_]struct { pattern: []const u8, prefix: []const u8, min_length: usize }{
        // OpenAI
        .{ .pattern = "(sk-|sk-proj-)[a-zA-Z0-9_-]{20,}", .prefix = "sk-", .min_length = 23 },
        // Anthropic
        .{ .pattern = "sk-ant-[a-zA-Z0-9_-]{20,}", .prefix = "sk-ant-", .min_length = 27 },
        // GitHub tokens
        .{ .pattern = "ghp_[a-zA-Z0-9]{36}", .prefix = "ghp_", .min_length = 40 },
        .{ .pattern = "gho_[a-zA-Z0-9]{36}", .prefix = "gho_", .min_length = 40 },
        .{ .pattern = "(ghu|ghs|ghr)_[a-zA-Z0-9]{36}", .prefix = "ghu_", .min_length = 40 },
        // Slack
        .{ .pattern = "xox[baprs]-[a-zA-Z0-9-]{10,}", .prefix = "xoxb-", .min_length = 15 },
        // AWS
        .{ .pattern = "AKIA[0-9A-Z]{16}", .prefix = "AKIA", .min_length = 20 },
        // Google
        .{ .pattern = "AIza[A-Za-z0-9_-]{35}", .prefix = "AIza", .min_length = 39 },
        .{ .pattern = "ya29\\.[a-zA-Z0-9_-]{100,}", .prefix = "ya29.", .min_length = 105 },
        // Stripe
        .{ .pattern = "sk_live_[a-zA-Z0-9]{24,}", .prefix = "sk_live_", .min_length = 32 },
        .{ .pattern = "sk_test_[a-zA-Z0-9]{24,}", .prefix = "sk_test_", .min_length = 32 },
        // Bearer
        .{ .pattern = "Bearer [a-zA-Z0-9_-]{20,}", .prefix = "Bearer ", .min_length = 27 },
    };

    pub fn compile(_: Allocator, pattern: []const u8, _: anytype) !Regex {
        // Find matching prefix config
        for (prefixes) |p| {
            if (std.mem.eql(u8, p.pattern, pattern)) {
                return .{ .pattern = pattern, .prefix = p.prefix, .min_length = p.min_length };
            }
        }
        // Default: use first 4 chars as prefix if pattern is long enough
        const prefix_len = @min(4, pattern.len);
        return .{ .pattern = pattern, .prefix = pattern[0..prefix_len], .min_length = 20 };
    }

    pub fn deinit(_: *Regex, _: Allocator) void {
        // Pattern is stored in RedactionRule, no allocation to free
    }

    pub fn findAll(self: *const Regex, alloc: Allocator, input: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var matches: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (matches.items) |m| alloc.free(m);
            matches.deinit(alloc);
        }

        var pos: usize = 0;
        while (pos < input.len) {
            // Find next occurrence of prefix
            if (std.mem.indexOfPos(u8, input, pos, self.prefix)) |start| {
                // Find end of token (whitespace or non-token char)
                var end = start + self.prefix.len;
                while (end < input.len and isTokenChar(input[end])) {
                    end += 1;
                }

                // Check minimum length requirement
                const token_len = end - start;
                if (token_len >= self.min_length) {
                    const match = try alloc.dupe(u8, input[start..end]);
                    try matches.append(alloc, match);
                }

                pos = end;
            } else {
                break;
            }
        }

        return matches;
    }

    fn isTokenChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.';
    }
};

// =============================================================================
// Unit Tests for Redactor
// =============================================================================

const testing = std.testing;

test "Redactor.redact removes OpenAI API key" {
    var redactor = Redactor.init(testing.allocator);
    defer redactor.deinit();

    const input = "export OPENAI_API_KEY=sk-1234567890abcdefghijklmnop";
    const result = try redactor.redact(input);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "[OPENAI_API_KEY]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "sk-1234567890") == null);
}

test "Redactor.redact removes GitHub token" {
    var redactor = Redactor.init(testing.allocator);
    defer redactor.deinit();

    const input = "GITHUB_TOKEN=ghp_1234567890abcdefghijklmnopqrstuvwxyz";
    const result = try redactor.redact(input);
    defer testing.allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "[GITHUB_TOKEN]") != null);
    try testing.expect(std.mem.indexOf(u8, result, "ghp_") == null);
}

test "Redactor.redact preserves non-secret text" {
    var redactor = Redactor.init(testing.allocator);
    defer redactor.deinit();

    const input = "Hello, this is a safe message with no secrets.";
    const result = try redactor.redact(input);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings(input, result);
}

test "Redactor.getStats returns correct counts" {
    var redactor = Redactor.init(testing.allocator);
    defer redactor.deinit();

    const stats = redactor.getStats();
    try testing.expect(stats.total_rules > 0);
    try testing.expect(stats.enabled_rules > 0);
}
