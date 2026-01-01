//! Secret Redaction Module
//!
//! This module provides automatic detection and redaction of sensitive data
//! before sending terminal content to AI providers.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Types of secrets that can be detected
pub const SecretType = enum {
    api_key,
    password,
    bearer_token,
    private_key,
    aws_key,
    github_token,
    database_url,
    jwt_token,
    generic_secret,
};

/// A detected secret with its location
pub const DetectedSecret = struct {
    secret_type: SecretType,
    start: usize,
    end: usize,
    original: []const u8,

    pub fn deinit(self: *const DetectedSecret, alloc: Allocator) void {
        alloc.free(self.original);
    }
};

/// Secret redaction patterns
const patterns = [_]struct {
    pattern: []const u8,
    secret_type: SecretType,
    prefix_match: bool, // If true, match as prefix; if false, match as regex-like
}{
    // API Keys
    .{ .pattern = "sk-", .secret_type = .api_key, .prefix_match = true }, // OpenAI
    .{ .pattern = "sk_live_", .secret_type = .api_key, .prefix_match = true }, // Stripe
    .{ .pattern = "sk_test_", .secret_type = .api_key, .prefix_match = true }, // Stripe
    .{ .pattern = "AKIA", .secret_type = .aws_key, .prefix_match = true }, // AWS Access Key
    .{ .pattern = "ghp_", .secret_type = .github_token, .prefix_match = true }, // GitHub PAT
    .{ .pattern = "gho_", .secret_type = .github_token, .prefix_match = true }, // GitHub OAuth
    .{ .pattern = "ghu_", .secret_type = .github_token, .prefix_match = true }, // GitHub User
    .{ .pattern = "ghs_", .secret_type = .github_token, .prefix_match = true }, // GitHub Server
    .{ .pattern = "github_pat_", .secret_type = .github_token, .prefix_match = true }, // New GitHub PAT
    .{ .pattern = "xox", .secret_type = .api_key, .prefix_match = true }, // Slack tokens
    .{ .pattern = "Bearer ", .secret_type = .bearer_token, .prefix_match = true },
    .{ .pattern = "eyJ", .secret_type = .jwt_token, .prefix_match = true }, // JWT tokens

    // Private keys
    .{ .pattern = "-----BEGIN RSA PRIVATE KEY-----", .secret_type = .private_key, .prefix_match = false },
    .{ .pattern = "-----BEGIN OPENSSH PRIVATE KEY-----", .secret_type = .private_key, .prefix_match = false },
    .{ .pattern = "-----BEGIN PRIVATE KEY-----", .secret_type = .private_key, .prefix_match = false },
    .{ .pattern = "-----BEGIN EC PRIVATE KEY-----", .secret_type = .private_key, .prefix_match = false },

    // Database URLs
    .{ .pattern = "postgres://", .secret_type = .database_url, .prefix_match = true },
    .{ .pattern = "postgresql://", .secret_type = .database_url, .prefix_match = true },
    .{ .pattern = "mysql://", .secret_type = .database_url, .prefix_match = true },
    .{ .pattern = "mongodb://", .secret_type = .database_url, .prefix_match = true },
    .{ .pattern = "mongodb+srv://", .secret_type = .database_url, .prefix_match = true },
    .{ .pattern = "redis://", .secret_type = .database_url, .prefix_match = true },
};

/// Environment variable patterns that likely contain secrets
const secret_env_patterns = [_][]const u8{
    "PASSWORD",
    "SECRET",
    "TOKEN",
    "API_KEY",
    "APIKEY",
    "PRIVATE_KEY",
    "ACCESS_KEY",
    "AUTH",
    "CREDENTIAL",
};

/// Secret Redactor
pub const SecretRedactor = struct {
    const Self = @This();

    alloc: Allocator,
    redaction_char: u8,
    redacted_label: []const u8,

    pub fn init(alloc: Allocator) Self {
        return .{
            .alloc = alloc,
            .redaction_char = '*',
            .redacted_label = "[REDACTED]",
        };
    }

    /// Detect secrets in text and return their locations
    pub fn detectSecrets(self: *Self, text: []const u8) !std.ArrayList(DetectedSecret) {
        var secrets = std.ArrayList(DetectedSecret).init(self.alloc);
        errdefer {
            for (secrets.items) |*s| s.deinit(self.alloc);
            secrets.deinit();
        }

        // Check each pattern
        for (patterns) |p| {
            var i: usize = 0;
            while (i < text.len) {
                if (std.mem.indexOf(u8, text[i..], p.pattern)) |offset| {
                    const start = i + offset;
                    const end = self.findSecretEnd(text, start, p.secret_type);

                    try secrets.append(.{
                        .secret_type = p.secret_type,
                        .start = start,
                        .end = end,
                        .original = try self.alloc.dupe(u8, text[start..end]),
                    });

                    i = end;
                } else {
                    break;
                }
            }
        }

        // Check for environment variable assignments with secret patterns
        try self.detectEnvSecrets(text, &secrets);

        return secrets;
    }

    /// Find the end of a secret value
    fn findSecretEnd(self: *Self, text: []const u8, start: usize, secret_type: SecretType) usize {
        _ = self;

        // For private keys, find the end marker
        if (secret_type == .private_key) {
            const end_markers = [_][]const u8{
                "-----END RSA PRIVATE KEY-----",
                "-----END OPENSSH PRIVATE KEY-----",
                "-----END PRIVATE KEY-----",
                "-----END EC PRIVATE KEY-----",
            };

            for (end_markers) |marker| {
                if (std.mem.indexOf(u8, text[start..], marker)) |offset| {
                    return start + offset + marker.len;
                }
            }
        }

        // For other secrets, find the end (whitespace or quote)
        var end = start;
        while (end < text.len) {
            const c = text[end];
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or
                c == '"' or c == '\'' or c == '`' or c == ';' or c == '&')
            {
                break;
            }
            end += 1;
        }

        return end;
    }

    /// Detect secrets in environment variable assignments
    fn detectEnvSecrets(self: *Self, text: []const u8, secrets: *std.ArrayList(DetectedSecret)) !void {
        // Look for patterns like KEY=value or export KEY=value
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_start: usize = 0;

        while (lines.next()) |line| {
            defer line_start += line.len + 1;

            // Skip comments
            const trimmed = std.mem.trimLeft(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check for env var assignment
            if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
                // Get the variable name (before =)
                var name_start: usize = 0;
                if (std.mem.indexOf(u8, line, "export ")) |exp_pos| {
                    name_start = exp_pos + 7;
                }
                const var_name = std.mem.trim(u8, line[name_start..eq_pos], " \t");

                // Check if variable name matches secret patterns
                for (secret_env_patterns) |pattern| {
                    if (std.mem.indexOf(u8, var_name, pattern) != null) {
                        // Found a secret env var
                        const value_start = line_start + eq_pos + 1;
                        var value_end = line_start + line.len;

                        // Remove quotes if present
                        if (line.len > eq_pos + 1) {
                            const first_char = line[eq_pos + 1];
                            if (first_char == '"' or first_char == '\'') {
                                // Find closing quote
                                if (std.mem.lastIndexOf(u8, line, &[_]u8{first_char})) |close_pos| {
                                    if (close_pos > eq_pos + 1) {
                                        value_end = line_start + close_pos;
                                    }
                                }
                            }
                        }

                        if (value_end > value_start) {
                            try secrets.append(.{
                                .secret_type = .generic_secret,
                                .start = value_start,
                                .end = value_end,
                                .original = try self.alloc.dupe(u8, text[value_start..value_end]),
                            });
                        }
                        break;
                    }
                }
            }
        }
    }

    /// Redact all detected secrets in text
    pub fn redact(self: *Self, text: []const u8) ![]u8 {
        const secrets = try self.detectSecrets(text);
        defer {
            for (secrets.items) |*s| s.deinit(self.alloc);
            secrets.deinit();
        }

        if (secrets.items.len == 0) {
            return try self.alloc.dupe(u8, text);
        }

        // Sort secrets by start position
        std.sort.insertion(DetectedSecret, secrets.items, {}, struct {
            fn cmp(_: void, a: DetectedSecret, b: DetectedSecret) bool {
                return a.start < b.start;
            }
        }.cmp);

        // Build redacted string
        var result = std.ArrayList(u8).init(self.alloc);
        errdefer result.deinit();

        var pos: usize = 0;
        for (secrets.items) |secret| {
            // Add text before secret
            if (secret.start > pos) {
                try result.appendSlice(text[pos..secret.start]);
            }

            // Add redaction label
            try result.appendSlice(self.redacted_label);

            pos = secret.end;
        }

        // Add remaining text
        if (pos < text.len) {
            try result.appendSlice(text[pos..]);
        }

        return result.toOwnedSlice();
    }

    /// Get a summary of what types of secrets were detected
    pub fn getSummary(self: *Self, text: []const u8) ![]SecretType {
        const secrets = try self.detectSecrets(text);
        defer {
            for (secrets.items) |*s| s.deinit(self.alloc);
            secrets.deinit();
        }

        var types = std.ArrayList(SecretType).init(self.alloc);
        errdefer types.deinit();

        for (secrets.items) |secret| {
            // Add unique types
            var found = false;
            for (types.items) |t| {
                if (t == secret.secret_type) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try types.append(secret.secret_type);
            }
        }

        return types.toOwnedSlice();
    }
};

/// Check if text contains any secrets
pub fn containsSecrets(text: []const u8) bool {
    for (patterns) |p| {
        if (std.mem.indexOf(u8, text, p.pattern) != null) {
            return true;
        }
    }

    // Check env patterns
    for (secret_env_patterns) |pattern| {
        if (std.mem.indexOf(u8, text, pattern) != null) {
            if (std.mem.indexOf(u8, text, "=") != null) {
                return true;
            }
        }
    }

    return false;
}
