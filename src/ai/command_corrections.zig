//! Command Corrections Module
//!
//! This module detects typos and errors in commands and suggests corrections.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_command_corrections);

/// A command correction suggestion
pub const CommandCorrection = struct {
    /// The corrected command
    corrected: []const u8,
    /// Original command
    original: []const u8,
    /// Type of correction
    correction_type: Type,
    /// Confidence score (0.0-1.0)
    confidence: f32,
    /// Explanation of the correction
    explanation: []const u8,

    pub const Type = enum {
        /// Typo correction (e.g., "gti" -> "git")
        typo,
        /// Flag correction (e.g., "--hel" -> "--help")
        flag_typo,
        /// Path correction
        path_correction,
        /// Command not found - suggest alternative
        command_not_found,
        /// Syntax correction
        syntax_correction,
    };

    pub fn deinit(self: *const CommandCorrection, alloc: Allocator) void {
        alloc.free(self.corrected);
        alloc.free(self.original);
        alloc.free(self.explanation);
    }
};

/// Common command names for typo detection
const common_commands = [_][]const u8{
    "git",  "npm", "docker", "kubectl", "cargo", "zig",  "python",  "node",
    "ls",   "cd",  "mkdir",  "rm",      "cp",    "mv",   "cat",     "grep",
    "find", "ps",  "kill",   "chmod",   "chown", "sudo", "ssh",     "scp",
    "tar",  "zip", "unzip",  "curl",    "wget",  "ping", "netstat", "top",
    "htop", "vim", "nano",
};

/// Common flag patterns
const common_flags = [_][]const u8{
    "--help", "--version", "--verbose",        "--quiet",       "--force",   "--recursive",
    "--all",  "--long",    "--human-readable", "--interactive", "--dry-run", "-h",
    "-v",     "-q",        "-f",               "-r",            "-a",        "-l",
    "-i",     "-n",
};

/// Command Corrections Service
pub const CommandCorrectionsService = struct {
    alloc: Allocator,
    enabled: bool,
    max_suggestions: usize,
    command_cache: StringHashMap([]const u8),

    /// Initialize the command corrections service
    pub fn init(alloc: Allocator, max_suggestions: usize) CommandCorrectionsService {
        return .{
            .alloc = alloc,
            .enabled = true,
            .max_suggestions = max_suggestions,
            .command_cache = StringHashMap([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *CommandCorrectionsService) void {
        var iter = self.command_cache.iterator();
        while (iter.next()) |entry| {
            self.alloc.free(entry.value_ptr.*);
        }
        self.command_cache.deinit();
    }

    /// Get corrections for a command
    pub fn getCorrections(
        self: *const CommandCorrectionsService,
        command: []const u8,
    ) !ArrayList(CommandCorrection) {
        var corrections = ArrayList(CommandCorrection).init(self.alloc);
        errdefer {
            for (corrections.items) |*c| c.deinit(self.alloc);
            corrections.deinit();
        }

        if (!self.enabled) return corrections;

        // Parse command into parts
        const parts = try self.parseCommand(command);
        defer {
            for (parts.items) |p| self.alloc.free(p);
            parts.deinit();
        }

        if (parts.items.len == 0) return corrections;

        const cmd_name = parts.items[0];

        // 1. Check for command name typos
        try self.checkCommandTypo(&corrections, cmd_name, command);

        // 2. Check for flag typos
        if (parts.items.len > 1) {
            for (parts.items[1..]) |part| {
                if (part.len > 0 and part[0] == '-') {
                    try self.checkFlagTypo(&corrections, part, command);
                }
            }
        }

        // 3. Check if command exists (using cache or PATH)
        if (!try self.commandExists(cmd_name)) {
            try self.suggestAlternatives(&corrections, cmd_name, command);
        }

        // Sort by confidence
        std.sort.insertion(CommandCorrection, corrections.items, {}, struct {
            fn compare(_: void, a: CommandCorrection, b: CommandCorrection) bool {
                return a.confidence > b.confidence;
            }
        }.compare);

        // Limit to max suggestions
        while (corrections.items.len > self.max_suggestions) {
            const removed = corrections.pop();
            removed.deinit(self.alloc);
        }

        return corrections;
    }

    /// Parse command into parts
    fn parseCommand(self: *const CommandCorrectionsService, command: []const u8) !ArrayList([]const u8) {
        var parts = ArrayList([]const u8).init(self.alloc);
        errdefer {
            for (parts.items) |p| self.alloc.free(p);
            parts.deinit();
        }

        var start: usize = 0;
        var in_quotes = false;
        var quote_char: u8 = 0;

        for (command, 0..) |c, i| {
            if (!in_quotes and (c == '"' or c == '\'')) {
                in_quotes = true;
                quote_char = c;
                start = i + 1;
            } else if (in_quotes and c == quote_char) {
                in_quotes = false;
                if (start < i) {
                    try parts.append(try self.alloc.dupe(u8, command[start..i]));
                }
                start = i + 1;
            } else if (!in_quotes and std.ascii.isWhitespace(c)) {
                if (start < i) {
                    try parts.append(try self.alloc.dupe(u8, command[start..i]));
                }
                start = i + 1;
            }
        }

        if (start < command.len) {
            try parts.append(try self.alloc.dupe(u8, command[start..]));
        }

        return parts;
    }

    /// Check for command name typos using Levenshtein distance
    fn checkCommandTypo(
        self: *const CommandCorrectionsService,
        corrections: *ArrayList(CommandCorrection),
        cmd_name: []const u8,
        original: []const u8,
    ) !void {
        var best_match: ?[]const u8 = null;
        var best_distance: usize = std.math.maxInt(usize);
        var best_confidence: f32 = 0.0;

        for (common_commands) |common_cmd| {
            const distance = self.levenshteinDistance(cmd_name, common_cmd);
            if (distance > 0 and distance <= 2) { // Allow up to 2 character differences
                if (distance < best_distance) {
                    best_distance = distance;
                    best_match = common_cmd;
                    best_confidence = 1.0 - (@as(f32, @floatFromInt(distance)) / 3.0);
                }
            }
        }

        if (best_match) |corrected| {
            // Reconstruct full command with correction
            const corrected_cmd = try std.fmt.allocPrint(
                self.alloc,
                "{s}{s}",
                .{ corrected, original[cmd_name.len..] },
            );

            try corrections.append(.{
                .corrected = corrected_cmd,
                .original = try self.alloc.dupe(u8, original),
                .correction_type = .typo,
                .confidence = best_confidence,
                .explanation = try std.fmt.allocPrint(
                    self.alloc,
                    "Did you mean '{s}'? (typo detected)",
                    .{corrected},
                ),
            });
        }
    }

    /// Check for flag typos
    fn checkFlagTypo(
        self: *const CommandCorrectionsService,
        corrections: *ArrayList(CommandCorrection),
        flag: []const u8,
        original: []const u8,
    ) !void {
        var best_match: ?[]const u8 = null;
        var best_distance: usize = std.math.maxInt(usize);

        for (common_flags) |common_flag| {
            const distance = self.levenshteinDistance(flag, common_flag);
            if (distance > 0 and distance <= 1) { // Allow 1 character difference for flags
                if (distance < best_distance) {
                    best_distance = distance;
                    best_match = common_flag;
                }
            }
        }

        if (best_match) |corrected_flag| {
            // Replace flag in original command
            const flag_start = std.mem.indexOf(u8, original, flag) orelse return;
            const before_flag = original[0..flag_start];
            const after_flag = original[flag_start + flag.len ..];

            const corrected_cmd = try std.fmt.allocPrint(
                self.alloc,
                "{s}{s}{s}",
                .{ before_flag, corrected_flag, after_flag },
            );

            try corrections.append(.{
                .corrected = corrected_cmd,
                .original = try self.alloc.dupe(u8, original),
                .correction_type = .flag_typo,
                .confidence = 0.9,
                .explanation = try std.fmt.allocPrint(
                    self.alloc,
                    "Did you mean flag '{s}'?",
                    .{corrected_flag},
                ),
            });
        }
    }

    /// Suggest alternatives when command not found
    fn suggestAlternatives(
        self: *const CommandCorrectionsService,
        corrections: *ArrayList(CommandCorrection),
        cmd_name: []const u8,
        original: []const u8,
    ) !void {
        // Find similar commands
        for (common_commands) |common_cmd| {
            const distance = self.levenshteinDistance(cmd_name, common_cmd);
            if (distance <= 3) {
                const corrected_cmd = try std.fmt.allocPrint(
                    self.alloc,
                    "{s}{s}",
                    .{ common_cmd, original[cmd_name.len..] },
                );

                const confidence = 1.0 - (@as(f32, @floatFromInt(distance)) / 4.0);
                if (confidence > 0.5) {
                    try corrections.append(.{
                        .corrected = corrected_cmd,
                        .original = try self.alloc.dupe(u8, original),
                        .correction_type = .command_not_found,
                        .confidence = confidence,
                        .explanation = try std.fmt.allocPrint(
                            self.alloc,
                            "Command '{s}' not found. Did you mean '{s}'?",
                            .{ cmd_name, common_cmd },
                        ),
                    });
                }
            }
        }
    }

    /// Check if command exists by searching in PATH
    fn commandExists(self: *const CommandCorrectionsService, cmd_name: []const u8) !bool {
        // Check cache first
        if (self.command_cache.get(cmd_name)) |result| {
            return result.len > 0;
        }

        // Get PATH environment variable
        const path_env = std.os.getenv("PATH") orelse return false;

        // Search each directory in PATH
        var path_iter = std.mem.splitScalar(u8, path_env, ':');
        while (path_iter.next()) |dir| {
            if (dir.len == 0) continue;

            // Construct full path
            const full_path = std.fs.path.join(self.alloc, &.{ dir, cmd_name }) catch continue;
            defer self.alloc.free(full_path);

            // Check if file exists and is executable
            _ = std.fs.accessAbsolute(full_path, .{ .mode = .read_only }) catch continue;

            // Cache the result
            const cached = try self.alloc.dupe(u8, full_path);
            self.command_cache.put(cmd_name, cached) catch {
                self.alloc.free(cached);
            };

            return true;
        }

        // Also check common commands for efficiency
        for (common_commands) |common| {
            if (std.mem.eql(u8, cmd_name, common)) {
                // Cache the result
                const cached = try self.alloc.dupe(u8, cmd_name);
                self.command_cache.put(cmd_name, cached) catch {
                    self.alloc.free(cached);
                };
                return true;
            }
        }

        // Cache negative result
        const cached_no = try self.alloc.dupe(u8, "");
        self.command_cache.put(cmd_name, cached_no) catch {
            self.alloc.free(cached_no);
        };

        return false;
    }

    /// Calculate Levenshtein distance between two strings with proper bounds checking
    fn levenshteinDistance(self: *const CommandCorrectionsService, a: []const u8, b: []const u8) usize {
        if (a.len == 0) return b.len;
        if (b.len == 0) return a.len;

        // Limit string length to prevent excessive memory usage
        const MAX_LEN = 100;
        if (a.len > MAX_LEN or b.len > MAX_LEN) {
            return std.math.maxInt(usize); // Too long, can't compute
        }

        // Allocate matrix on the heap
        const matrix_size = (a.len + 1) * (b.len + 1);
        const matrix = self.alloc.alloc(usize, matrix_size) catch return std.math.maxInt(usize);
        defer self.alloc.free(matrix);

        // Initialize matrix using 2D indexing
        for (0..a.len + 1) |i| {
            matrix[i * (b.len + 1) + 0] = i;
        }
        for (0..b.len + 1) |j| {
            matrix[0 * (b.len + 1) + j] = j;
        }

        // Calculate distances
        for (a, 1..) |a_char, i| {
            for (b, 1..) |b_char, j| {
                const cost: usize = if (a_char == b_char) 0 else 1;
                const left = matrix[i * (b.len + 1) + (j - 1)] + 1;
                const up = matrix[(i - 1) * (b.len + 1) + j] + 1;
                const diagonal = matrix[(i - 1) * (b.len + 1) + (j - 1)] + cost;
                matrix[i * (b.len + 1) + j] = @min(@min(left, up), diagonal);
            }
        }

        return matrix[a.len * (b.len + 1) + b.len];
    }

    /// Enable or disable corrections
    pub fn setEnabled(self: *CommandCorrectionsService, enabled: bool) void {
        self.enabled = enabled;
    }
};
