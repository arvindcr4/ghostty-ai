//! Security Enhancements Module
//!
//! This module provides advanced secret detection and security features:
//! - Secret detection using pattern matching
//! - Entropy-based detection for high-randomness strings
//! - Context-aware scanning (file extensions, common patterns)
//! - Redaction capabilities for safe logging
//!
//! The module supports both regex (via oniguruma) and string-based pattern matching.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_security);

/// Detected secret
pub const DetectedSecret = struct {
    secret_type: SecretType,
    value: []const u8,
    redacted_value: []const u8,
    location: Location,
    confidence: f32,
    suggestion: []const u8,
    pattern_name: []const u8,

    pub const SecretType = enum {
        api_key,
        password,
        token,
        private_key,
        aws_key,
        gcp_key,
        azure_key,
        database_url,
        credit_card,
        ssn,
        ssh_key,
        encryption_key,
        jwt,
        generic_secret,
    };

    pub const Location = struct {
        offset: usize,
        line: usize,
        column: usize,
        context: []const u8,
    };

    pub fn deinit(self: *const DetectedSecret, alloc: Allocator) void {
        alloc.free(self.value);
        alloc.free(self.redacted_value);
        alloc.free(self.location.context);
        alloc.free(self.suggestion);
        alloc.free(self.pattern_name);
    }
};

/// Secret pattern definition
pub const SecretPattern = struct {
    name: []const u8,
    prefixes: []const []const u8,
    min_length: usize,
    max_length: usize,
    secret_type: DetectedSecret.SecretType,
    char_set: CharSet,
    require_entropy: bool,
    entropy_threshold: f32,

    pub const CharSet = enum {
        alphanumeric,
        alphanumeric_special,
        base64,
        hex,
        any,
    };
};

/// Security scanner configuration
pub const ScannerConfig = struct {
    /// Enable secret scanning
    enabled: bool = true,
    /// Minimum entropy threshold for generic detection
    min_entropy: f32 = 3.5,
    /// Enable context-aware scanning
    context_aware: bool = true,
    /// Maximum secrets to report per scan
    max_secrets: usize = 100,
    /// Include line context in results
    include_context: bool = true,
    /// Context lines before/after secret
    context_lines: usize = 1,
};

/// Advanced Security Scanner
pub const SecurityScanner = struct {
    alloc: Allocator,
    config: ScannerConfig,
    patterns: ArrayListUnmanaged(SecretPattern),
    custom_patterns: ArrayListUnmanaged(SecretPattern),
    scan_history: ArrayListUnmanaged(ScanResult),

    pub const ScanResult = struct {
        timestamp: i64,
        secrets_found: usize,
        scan_type: ScanType,
        source: []const u8,

        pub const ScanType = enum {
            text,
            file,
            command,
            output,
        };
    };

    /// Initialize security scanner
    pub fn init(alloc: Allocator) SecurityScanner {
        var scanner = SecurityScanner{
            .alloc = alloc,
            .config = .{},
            .patterns = .empty,
            .custom_patterns = .empty,
            .scan_history = .empty,
        };

        scanner.registerDefaultPatterns() catch |err| {
            log.err("Failed to register default patterns: {}", .{err});
        };

        return scanner;
    }

    pub fn deinit(self: *SecurityScanner) void {
        self.patterns.deinit(self.alloc);
        self.custom_patterns.deinit(self.alloc);
        for (self.scan_history.items) |*item| {
            self.alloc.free(item.source);
        }
        self.scan_history.deinit(self.alloc);
    }

    /// Configure the scanner
    pub fn configure(self: *SecurityScanner, config: ScannerConfig) void {
        self.config = config;
    }

    /// Register default secret patterns
    fn registerDefaultPatterns(self: *SecurityScanner) !void {
        // OpenAI API Keys
        try self.patterns.append(self.alloc, .{
            .name = "OpenAI API Key",
            .prefixes = &[_][]const u8{ "sk-", "sk-proj-" },
            .min_length = 20,
            .max_length = 200,
            .secret_type = .api_key,
            .char_set = .alphanumeric_special,
            .require_entropy = true,
            .entropy_threshold = 3.5,
        });

        // Anthropic API Keys
        try self.patterns.append(self.alloc, .{
            .name = "Anthropic API Key",
            .prefixes = &[_][]const u8{"sk-ant-"},
            .min_length = 20,
            .max_length = 200,
            .secret_type = .api_key,
            .char_set = .alphanumeric_special,
            .require_entropy = true,
            .entropy_threshold = 3.5,
        });

        // GitHub Personal Access Tokens
        try self.patterns.append(self.alloc, .{
            .name = "GitHub PAT",
            .prefixes = &[_][]const u8{ "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_" },
            .min_length = 36,
            .max_length = 100,
            .secret_type = .api_key,
            .char_set = .alphanumeric,
            .require_entropy = true,
            .entropy_threshold = 3.0,
        });

        // AWS Keys
        try self.patterns.append(self.alloc, .{
            .name = "AWS Access Key ID",
            .prefixes = &[_][]const u8{ "AKIA", "ABIA", "ACCA", "AGPA", "AIDA", "AIPA", "ANPA", "ANVA", "APKA", "AROA", "ASCA", "ASIA" },
            .min_length = 20,
            .max_length = 20,
            .secret_type = .aws_key,
            .char_set = .alphanumeric,
            .require_entropy = false,
            .entropy_threshold = 0,
        });

        // Slack Tokens
        try self.patterns.append(self.alloc, .{
            .name = "Slack Token",
            .prefixes = &[_][]const u8{ "xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-" },
            .min_length = 20,
            .max_length = 255,
            .secret_type = .token,
            .char_set = .alphanumeric_special,
            .require_entropy = true,
            .entropy_threshold = 3.0,
        });

        // Google Cloud Keys
        try self.patterns.append(self.alloc, .{
            .name = "Google Cloud API Key",
            .prefixes = &[_][]const u8{"AIza"},
            .min_length = 35,
            .max_length = 45,
            .secret_type = .gcp_key,
            .char_set = .alphanumeric_special,
            .require_entropy = true,
            .entropy_threshold = 3.0,
        });

        // Azure Keys
        try self.patterns.append(self.alloc, .{
            .name = "Azure Subscription Key",
            .prefixes = &[_][]const u8{},
            .min_length = 32,
            .max_length = 32,
            .secret_type = .azure_key,
            .char_set = .hex,
            .require_entropy = true,
            .entropy_threshold = 3.5,
        });

        // JWT Tokens
        try self.patterns.append(self.alloc, .{
            .name = "JWT Token",
            .prefixes = &[_][]const u8{"eyJ"},
            .min_length = 30,
            .max_length = 2000,
            .secret_type = .jwt,
            .char_set = .base64,
            .require_entropy = false,
            .entropy_threshold = 0,
        });

        // Private Keys (RSA, EC, DSA)
        try self.patterns.append(self.alloc, .{
            .name = "Private Key",
            .prefixes = &[_][]const u8{ "-----BEGIN RSA PRIVATE KEY", "-----BEGIN EC PRIVATE KEY", "-----BEGIN PRIVATE KEY", "-----BEGIN DSA PRIVATE KEY", "-----BEGIN OPENSSH PRIVATE KEY" },
            .min_length = 100,
            .max_length = 10000,
            .secret_type = .private_key,
            .char_set = .any,
            .require_entropy = false,
            .entropy_threshold = 0,
        });

        // Database URLs
        try self.patterns.append(self.alloc, .{
            .name = "Database URL",
            .prefixes = &[_][]const u8{ "postgres://", "postgresql://", "mysql://", "mongodb://", "mongodb+srv://", "redis://", "amqp://" },
            .min_length = 20,
            .max_length = 500,
            .secret_type = .database_url,
            .char_set = .any,
            .require_entropy = false,
            .entropy_threshold = 0,
        });

        // SSH Private Keys
        try self.patterns.append(self.alloc, .{
            .name = "SSH Private Key",
            .prefixes = &[_][]const u8{"-----BEGIN OPENSSH PRIVATE KEY"},
            .min_length = 100,
            .max_length = 5000,
            .secret_type = .ssh_key,
            .char_set = .any,
            .require_entropy = false,
            .entropy_threshold = 0,
        });
    }

    /// Add a custom pattern
    pub fn addCustomPattern(self: *SecurityScanner, pattern: SecretPattern) !void {
        try self.custom_patterns.append(self.alloc, pattern);
    }

    /// Scan text for secrets
    pub fn scan(self: *SecurityScanner, text: []const u8) !ArrayListUnmanaged(DetectedSecret) {
        return self.scanWithType(text, .text, "inline");
    }

    /// Scan text with type and source information
    pub fn scanWithType(
        self: *SecurityScanner,
        text: []const u8,
        scan_type: ScanResult.ScanType,
        source: []const u8,
    ) !ArrayListUnmanaged(DetectedSecret) {
        var secrets: ArrayListUnmanaged(DetectedSecret) = .empty;
        errdefer {
            for (secrets.items) |*s| s.deinit(self.alloc);
            secrets.deinit(self.alloc);
        }

        if (!self.config.enabled) return secrets;

        // Scan with default patterns
        for (self.patterns.items) |pattern| {
            try self.scanWithPattern(text, &pattern, &secrets);
        }

        // Scan with custom patterns
        for (self.custom_patterns.items) |pattern| {
            try self.scanWithPattern(text, &pattern, &secrets);
        }

        // High-entropy detection for generic secrets
        if (self.config.context_aware) {
            try self.scanForHighEntropy(text, &secrets);
        }

        // Limit results
        if (secrets.items.len > self.config.max_secrets) {
            while (secrets.items.len > self.config.max_secrets) {
                if (secrets.pop()) |removed| {
                    removed.deinit(self.alloc);
                }
            }
        }

        // Record scan history
        try self.scan_history.append(self.alloc, .{
            .timestamp = std.time.timestamp(),
            .secrets_found = secrets.items.len,
            .scan_type = scan_type,
            .source = try self.alloc.dupe(u8, source),
        });

        return secrets;
    }

    /// Scan text with a specific pattern
    fn scanWithPattern(
        self: *SecurityScanner,
        text: []const u8,
        pattern: *const SecretPattern,
        secrets: *ArrayListUnmanaged(DetectedSecret),
    ) !void {
        // Try each prefix
        for (pattern.prefixes) |prefix| {
            var offset: usize = 0;
            while (offset < text.len) {
                // Find prefix
                const idx = std.mem.indexOfPos(u8, text, offset, prefix) orelse break;

                // Extract potential secret
                const secret_start = idx;
                const secret_end = self.findSecretEnd(text, idx + prefix.len, pattern);
                const secret_len = secret_end - secret_start;

                // Validate length
                if (secret_len >= pattern.min_length and secret_len <= pattern.max_length) {
                    const secret_value = text[secret_start..secret_end];

                    // Check character set
                    if (self.validateCharSet(secret_value, pattern.char_set)) {
                        // Check entropy if required
                        const entropy = calculateEntropy(secret_value);
                        if (!pattern.require_entropy or entropy >= pattern.entropy_threshold) {
                            // Get location info
                            const location = self.getLocation(text, secret_start);

                            try secrets.append(self.alloc, .{
                                .secret_type = pattern.secret_type,
                                .value = try self.alloc.dupe(u8, secret_value),
                                .redacted_value = try self.redact(secret_value),
                                .location = location,
                                .confidence = @min(entropy / 4.0, 1.0),
                                .suggestion = try self.alloc.dupe(u8, getSuggestion(pattern.secret_type)),
                                .pattern_name = try self.alloc.dupe(u8, pattern.name),
                            });
                        }
                    }
                }

                offset = idx + 1;
            }
        }

        // Handle patterns without prefixes (scan entire text)
        if (pattern.prefixes.len == 0) {
            try self.scanWithoutPrefix(text, pattern, secrets);
        }
    }

    /// Scan for patterns without a prefix
    fn scanWithoutPrefix(
        self: *SecurityScanner,
        text: []const u8,
        pattern: *const SecretPattern,
        secrets: *ArrayListUnmanaged(DetectedSecret),
    ) !void {
        // Look for assignment patterns (key=value, key: value)
        const assignment_patterns = [_][]const u8{
            "password=",    "password:",    "PASSWORD=",    "PASSWORD:",
            "api_key=",     "api_key:",     "API_KEY=",     "API_KEY:",
            "apikey=",      "apikey:",      "APIKEY=",      "APIKEY:",
            "secret=",      "secret:",      "SECRET=",      "SECRET:",
            "token=",       "token:",       "TOKEN=",       "TOKEN:",
            "private_key=", "private_key:", "PRIVATE_KEY=", "PRIVATE_KEY:",
        };

        for (assignment_patterns) |assign_pattern| {
            var offset: usize = 0;
            while (offset < text.len) {
                const idx = std.mem.indexOfPos(u8, text, offset, assign_pattern) orelse break;
                const value_start = idx + assign_pattern.len;

                // Skip whitespace and quotes
                var actual_start = value_start;
                while (actual_start < text.len and (text[actual_start] == ' ' or text[actual_start] == '"' or text[actual_start] == '\'')) {
                    actual_start += 1;
                }

                const value_end = self.findSecretEnd(text, actual_start, pattern);
                const value_len = value_end - actual_start;

                if (value_len >= pattern.min_length and value_len <= pattern.max_length) {
                    const secret_value = text[actual_start..value_end];
                    const entropy = calculateEntropy(secret_value);

                    if (entropy >= self.config.min_entropy) {
                        const location = self.getLocation(text, actual_start);

                        try secrets.append(self.alloc, .{
                            .secret_type = pattern.secret_type,
                            .value = try self.alloc.dupe(u8, secret_value),
                            .redacted_value = try self.redact(secret_value),
                            .location = location,
                            .confidence = @min(entropy / 4.0, 1.0),
                            .suggestion = try self.alloc.dupe(u8, getSuggestion(pattern.secret_type)),
                            .pattern_name = try self.alloc.dupe(u8, "Generic Assignment"),
                        });
                    }
                }

                offset = idx + 1;
            }
        }
    }

    /// Scan for high-entropy strings (potential secrets)
    fn scanForHighEntropy(
        self: *SecurityScanner,
        text: []const u8,
        secrets: *ArrayListUnmanaged(DetectedSecret),
    ) !void {
        // Look for quoted strings with high entropy
        const quote_chars = [_]u8{ '"', '\'' };

        for (quote_chars) |quote| {
            var offset: usize = 0;
            while (offset < text.len) {
                const start = std.mem.indexOfScalarPos(u8, text, offset, quote) orelse break;
                if (start + 1 >= text.len) break;

                const end = std.mem.indexOfScalarPos(u8, text, start + 1, quote) orelse break;
                const content = text[start + 1 .. end];

                // Check if content looks like a secret
                if (content.len >= 16 and content.len <= 200) {
                    const entropy = calculateEntropy(content);
                    if (entropy >= self.config.min_entropy) {
                        // Avoid duplicates
                        var is_duplicate = false;
                        for (secrets.items) |existing| {
                            if (std.mem.eql(u8, existing.value, content)) {
                                is_duplicate = true;
                                break;
                            }
                        }

                        if (!is_duplicate) {
                            const location = self.getLocation(text, start + 1);

                            try secrets.append(self.alloc, .{
                                .secret_type = .generic_secret,
                                .value = try self.alloc.dupe(u8, content),
                                .redacted_value = try self.redact(content),
                                .location = location,
                                .confidence = @min((entropy - 3.0) / 2.0, 0.8),
                                .suggestion = try self.alloc.dupe(u8, "This high-entropy string may be a secret. Consider using environment variables."),
                                .pattern_name = try self.alloc.dupe(u8, "High Entropy String"),
                            });
                        }
                    }
                }

                offset = end + 1;
            }
        }
    }

    /// Find the end of a secret value
    fn findSecretEnd(_: *const SecurityScanner, text: []const u8, start: usize, pattern: *const SecretPattern) usize {
        var end = start;
        const max_end = @min(start + pattern.max_length, text.len);

        while (end < max_end) {
            const c = text[end];

            // Stop at whitespace or common delimiters
            if (c == ' ' or c == '\n' or c == '\r' or c == '\t' or
                c == '"' or c == '\'' or c == ',' or c == ';' or
                c == ')' or c == ']' or c == '}' or c == '>' or
                c == '&' or c == '|')
            {
                break;
            }

            end += 1;
        }

        return end;
    }

    /// Validate that text matches expected character set
    fn validateCharSet(_: *const SecurityScanner, text: []const u8, char_set: SecretPattern.CharSet) bool {
        return switch (char_set) {
            .alphanumeric => blk: {
                for (text) |c| {
                    if (!std.ascii.isAlphanumeric(c)) break :blk false;
                }
                break :blk true;
            },
            .alphanumeric_special => blk: {
                for (text) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') break :blk false;
                }
                break :blk true;
            },
            .base64 => blk: {
                for (text) |c| {
                    if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '/' and c != '=' and c != '-' and c != '_') break :blk false;
                }
                break :blk true;
            },
            .hex => blk: {
                for (text) |c| {
                    if (!std.ascii.isHex(c)) break :blk false;
                }
                break :blk true;
            },
            .any => true,
        };
    }

    /// Get location information for an offset
    fn getLocation(self: *const SecurityScanner, text: []const u8, offset: usize) DetectedSecret.Location {
        var line: usize = 1;
        var column: usize = 1;
        var last_newline: usize = 0;

        for (text[0..offset], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                column = 1;
                last_newline = i + 1;
            } else {
                column += 1;
            }
        }

        // Extract context
        const context_start = if (last_newline > 0) last_newline else 0;
        var context_end = offset;
        while (context_end < text.len and text[context_end] != '\n') {
            context_end += 1;
        }
        const context = self.alloc.dupe(u8, text[context_start..context_end]) catch "";

        return .{
            .offset = offset,
            .line = line,
            .column = column,
            .context = context,
        };
    }

    /// Redact a secret value for safe display
    fn redact(self: *SecurityScanner, value: []const u8) ![]const u8 {
        if (value.len <= 8) {
            return try self.alloc.dupe(u8, "***");
        }

        const prefix_len = @min(4, value.len / 4);
        const suffix_len = @min(4, value.len / 4);

        return try std.fmt.allocPrint(
            self.alloc,
            "{s}***{s}",
            .{ value[0..prefix_len], value[value.len - suffix_len ..] },
        );
    }

    /// Enable or disable scanning
    pub fn setEnabled(self: *SecurityScanner, enabled: bool) void {
        self.config.enabled = enabled;
    }

    /// Get scan statistics
    pub fn getStats(self: *const SecurityScanner) struct {
        total_scans: usize,
        total_secrets_found: usize,
        patterns_loaded: usize,
    } {
        var total_secrets: usize = 0;
        for (self.scan_history.items) |entry| {
            total_secrets += entry.secrets_found;
        }

        return .{
            .total_scans = self.scan_history.items.len,
            .total_secrets_found = total_secrets,
            .patterns_loaded = self.patterns.items.len + self.custom_patterns.items.len,
        };
    }
};

/// Calculate Shannon entropy of a string
pub fn calculateEntropy(text: []const u8) f32 {
    if (text.len == 0) return 0.0;

    var char_counts: [256]u32 = [_]u32{0} ** 256;

    for (text) |c| {
        char_counts[c] += 1;
    }

    var entropy: f32 = 0.0;
    const len_f = @as(f32, @floatFromInt(text.len));

    for (char_counts) |count| {
        if (count > 0) {
            const probability = @as(f32, @floatFromInt(count)) / len_f;
            entropy -= probability * @log2(probability);
        }
    }

    return entropy;
}

/// Get remediation suggestion for secret type
fn getSuggestion(secret_type: DetectedSecret.SecretType) []const u8 {
    return switch (secret_type) {
        .api_key => "Use environment variables or a secrets manager instead of hardcoding API keys",
        .password => "Never commit passwords. Use environment variables or a secure vault",
        .token => "Tokens should be stored securely and never committed to version control",
        .private_key => "Private keys must never be shared. Regenerate this key immediately",
        .aws_key => "AWS credentials should be managed via IAM roles or environment variables",
        .gcp_key => "GCP credentials should use service accounts with minimal permissions",
        .azure_key => "Azure credentials should use managed identities or Key Vault",
        .database_url => "Database credentials should be stored in environment variables",
        .credit_card => "Credit card numbers are highly sensitive and subject to PCI compliance",
        .ssn => "Social Security Numbers are PII and should be encrypted at rest",
        .ssh_key => "SSH private keys should never be shared. Use ssh-agent for key management",
        .encryption_key => "Encryption keys must be stored in a hardware security module or KMS",
        .jwt => "JWTs should have appropriate expiration and be transmitted securely",
        .generic_secret => "This appears to be a secret. Store it securely using environment variables or a secrets manager",
    };
}

test "SecurityScanner basic operations" {
    const alloc = std.testing.allocator;

    var scanner = SecurityScanner.init(alloc);
    defer scanner.deinit();

    // Test that scanner initializes correctly
    try std.testing.expect(scanner.config.enabled);
    try std.testing.expect(scanner.patterns.items.len > 0);

    // Test scanning
    const test_text = "my api_key=sk-ant-api03-test1234567890abcdef1234567890";
    var secrets = try scanner.scan(test_text);
    defer {
        for (secrets.items) |*s| s.deinit(alloc);
        secrets.deinit(alloc);
    }

    // Should find the Anthropic key
    try std.testing.expect(secrets.items.len > 0);
}

test "calculateEntropy" {
    // Low entropy (repeated chars)
    const low_entropy = calculateEntropy("aaaaaaaaaa");
    try std.testing.expect(low_entropy < 1.0);

    // High entropy (random-looking)
    const high_entropy = calculateEntropy("aB3$xY9@zQ1&wK5");
    try std.testing.expect(high_entropy > 3.0);
}
