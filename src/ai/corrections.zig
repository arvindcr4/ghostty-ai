//! Command Corrections Module
//!
//! This module provides intelligent command correction suggestions
//! for typos, misspelled commands, and missing parameters.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_corrections);

/// Common command typos and their corrections
const common_typos = std.ComptimeStringMap([]const u8, .{
    // Git typos
    .{ "gi", "git" },
    .{ "gti", "git" },
    .{ "got", "git" },
    .{ "gut", "git" },
    .{ "gti", "git" },

    // NPM typos
    .{ "npm", "npm" },
    .{ "npm", "npm" },
    .{ "pnm", "npm" },

    // Docker typos
    .{ "docer", "docker" },
    .{ "doker", "docker" },
    .{ "odcker", "docker" },

    // Kubernetes typos
    .{ "kuctl", "kubectl" },
    .{ "kubctl", "kubectl" },
    .{ "kubetcl", "kubectl" },

    // System typos
    .{ "sudu", "sudo" },
    .{ "sduo", "sudo" },
    .{ "suod", "sudo" },
    .{ "sudo", "sudo" },

    // Other common typos
    .{ "grpe", "grep" },
    .{ "gerp", "grep" },
    .{ "ls", "ls" },
    .{ "sl", "ls" },
    .{ "cd", "cd" },
    .{ "dc", "cd" },
    .{ "cat", "cat" },
    .{ "act", "cat" },
    .{ "vim", "vim" },
    .{ "ivm", "vim" },
    .{ "vi", "vi" },
    .{ "nvim", "nvim" },
    .{ "nivm", "nvim" },
    .{ "yarn", "yarn" },
    .{ "yran", "yarn" },
    .{ "pip", "pip" },
    .{ "ipp", "pip" },
    .{ "cargo", "cargo" },
    .{ "carg", "cargo" },
    .{ "python", "python" },
    .{ "pytohn", "python" },
    .{ "pyhton", "python" },
    .{ "node", "node" },
    .{ "nede", "node" },
    .{ "npm", "npm" },
    .{ "yarn", "yarn" },
    .{ "make", "make" },
    .{ "maek", "make" },
    .{ "cmake", "cmake" },
    .{ "cmaek", "cmake" },
});

/// Suggested correction
pub const Correction = struct {
    original: []const u8,
    corrected: []const u8,
    reason: []const u8,
    confidence: f32, // 0.0 to 1.0
};

/// Command Corrections Service
pub const CorrectionsService = struct {
    alloc: Allocator,
    command_db: StringHashMap(void),

    /// Initialize the corrections service
    pub fn init(alloc: Allocator) !CorrectionsService {
        var service = CorrectionsService{
            .alloc = alloc,
            .command_db = StringHashMap(void).init(alloc),
        };

        // Initialize with common commands (could be loaded from file)
        try service.loadCommonCommands();

        return service;
    }

    pub fn deinit(self: *CorrectionsService) void {
        self.command_db.deinit();
    }

    /// Load common commands into the database
    fn loadCommonCommands(self: *CorrectionsService) !void {
        // Common Unix commands
        const common_commands = [_][]const u8{
            "ls",    "cd",    "pwd",   "cat",   "grep",  "find",
            "rm",    "cp",    "mv",    "mkdir", "rmdir", "touch",
            "chmod", "chown", "chgrp", "ln",    "tar",   "zip",
            "unzip", "gzip",  "gunzip","head",  "tail",  "less",
            "more",  "sort",  "uniq",  "wc",    "cut",   "paste",
            "tr",    "sed",   "awk",   "vim",   "vi",    "nano",
            "emacs", "top",   "htop",  "ps",    "kill",  "killall",
            "sudo",  "su",    "man",   "help",  "exit",  "logout",
            // Development tools
            "git",   "npm",   "yarn",  "pip",   "cargo", "go",
            "rustc", "python","node",  "deno",  "bun",   "docker",
            "kubectl","make", "cmake", "gcc",   "clang", "javac",
            "java",  "mvn",   "gradle","curl",  "wget",  "ssh",
            "scp",   "rsync", "tar",   "gzip",  "unzip",
        };

        for (common_commands) |cmd| {
            try self.command_db.put(cmd, {});
        }
    }

    /// Check if a command exists in the database
    fn commandExists(self: *const CorrectionsService, cmd: []const u8) bool {
        return self.command_db.get(cmd) != null;
    }

    /// Calculate Levenshtein distance between two strings
    fn levenshteinDistance(self: *const CorrectionsService, a: []const u8, b: []const u8) !usize {
        const len_a = a.len;
        const len_b = b.len;

        if (len_a == 0) return len_b;
        if (len_b == 0) return len_a;

        // Use a smaller buffer for optimization
        var row0 = try self.alloc.alloc(usize, len_b + 1);
        defer self.alloc.free(row0);
        var row1 = try self.alloc.alloc(usize, len_b + 1);
        defer self.alloc.free(row1);

        for (0..len_b + 1) |j| {
            row0[j] = j;
        }

        for (0..len_a) |i| {
            row1[0] = i + 1;

            for (0..len_b) |j| {
                const cost = if (a[i] == b[j]) @as(usize, 0) else 1;
                row1[j + 1] = @min(
                    row1[j] + 1, // deletion
                    @min(
                        row0[j + 1] + 1, // insertion
                        row0[j] + cost, // substitution
                    ),
                );
            }

            // Swap rows
            const tmp = row0;
            row0 = row1;
            row1 = tmp;
        }

        return row0[len_b];
    }

    /// Find closest matching command
    fn findClosestCommand(self: *const CorrectionsService, input: []const u8) !?struct {
        command: []const u8,
        distance: usize,
    } {
        if (input.len == 0) return null;

        var best_match: ?struct {
            command: []const u8,
            distance: usize,
        } = null;
        var best_distance: usize = std.math.maxInt(usize);

        var iter = self.command_db.iterator();
        while (iter.next()) |entry| {
            const cmd = entry.key_ptr.*;

            // Skip if length difference is too large (>3 chars)
            if (@abs(@as(isize, @intCast(cmd.len)) - @as(isize, @intCast(input.len))) > 3) {
                continue;
            }

            const dist = try self.levenshteinDistance(input, cmd);

            // Only consider matches with distance <= 2
            if (dist <= 2 and dist < best_distance) {
                best_distance = dist;
                best_match = .{ .command = cmd, .distance = dist };

                // Perfect match
                if (dist == 0) break;
            }
        }

        return best_match;
    }

    /// Suggest correction for a command
    pub fn suggestCorrection(self: *const CorrectionsService, command: []const u8) !?Correction {
        if (command.len == 0) return null;

        // Trim whitespace
        const trimmed = std.mem.trim(u8, command, &std.ascii.whitespace);
        if (trimmed.len == 0) return null;

        // Get the first word (the command name)
        const cmd_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
        const cmd_name = trimmed[0..cmd_end];

        // Check common typos first (highest confidence)
        if (common_typos.get(cmd_name)) |correction| {
            return Correction{
                .original = command,
                .corrected = correction,
                .reason = "Common typo",
                .confidence = 0.95,
            };
        }

        // Check if command exists
        if (self.commandExists(cmd_name)) {
            return null; // No correction needed
        }

        // Find closest match
        const match = try self.findClosestCommand(cmd_name);

        if (match) |m| {
            const confidence = switch (m.distance) {
                1 => 0.9,
                2 => 0.7,
                else => 0.5,
            };

            // Build corrected command
            const corrected = try std.fmt.allocPrint(
                self.alloc,
                "{s}{s}",
                .{ m.command, trimmed[cmd_end..] },
            );

            return Correction{
                .original = command,
                .corrected = corrected,
                .reason = "Did you mean?",
                .confidence = confidence,
            };
        }

        return null;
    }

    /// Check for missing parameters and suggest completions
    pub fn checkMissingParams(self: *const CorrectionsService, command: []const u8) ![]const []const u8 {
        _ = self;
        _ = command;

        // This would need command specification database
        // For now, return empty list
        return &[_][]const u8{};
    }

    /// Auto-correct a command (returns the corrected version)
    pub fn autoCorrect(self: *const CorrectionsService, command: []const u8) ![]const u8 {
        const correction = try self.suggestCorrection(command);

        if (correction) |c| {
            if (c.confidence >= 0.8) {
                // High confidence, auto-correct
                return try self.alloc.dupe(u8, c.corrected);
            }
        }

        // No correction or low confidence, return original
        return try self.alloc.dupe(u8, command);
    }
};
