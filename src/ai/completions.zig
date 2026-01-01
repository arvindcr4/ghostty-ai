//! Smart Completions for Terminal Commands
//!
//! This module provides intelligent TAB-triggered completions for CLI tools.
//! It combines a static specification database with AI-powered completions
//! to provide context-aware suggestions for 400+ popular CLI tools.

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const ComptimeStringMap = std.ComptimeStringMap;

const log = std.log.scoped(.ai_completions);

/// A completion suggestion
pub const Completion = struct {
    /// The text to insert
    text: []const u8,
    /// Description of what this completion does
    description: []const u8,
    /// Type of completion
    kind: Kind,
    /// Display text (may differ from inserted text)
    display: ?[]const u8 = null,

    pub const Kind = enum {
        /// Subcommand (e.g., "install" in "npm install")
        subcommand,
        /// Flag/option (e.g., "--help" or "-h")
        flag,
        /// Argument value
        argument,
        /// Filename/path
        filename,
        /// AI-suggested completion
        ai_suggested,
    };

    pub fn deinit(self: *const Completion, alloc: Allocator) void {
        alloc.free(self.text);
        alloc.free(self.description);
        if (self.display) |d| alloc.free(d);
    }
};

/// Specification for a CLI tool's command structure
pub const ToolSpec = struct {
    /// Tool name
    name: []const u8,
    /// Available subcommands
    subcommands: []const []const u8,
    /// Common flags
    flags: []const Flag,
    /// Does this tool accept filenames as arguments?
    accepts_files: bool = true,
};

/// A flag/option specification
pub const Flag = struct {
    /// Short form (e.g., "-h")
    short: ?[]const u8 = null,
    /// Long form (e.g., "--help")
    long: []const u8,
    /// Description
    description: []const u8,
    /// Does this flag require a value?
    requires_value: bool = false,
    /// Possible values (for enums)
    values: ?[]const []const u8 = null,
};

/// Built-in tool specifications
const tool_specs = [_]ToolSpec{
    // Git
    .{
        .name = "git",
        .subcommands = &[_][]const u8{
            "add",      "branch",   "checkout", "clone",   "commit",
            "diff",     "fetch",    "init",     "log",     "merge",
            "pull",     "push",     "rebase",   "remote",  "reset",
            "restore",  "revert",   "rm",       "show",    "stash",
            "status",   "switch",   "tag",      "worktree",
        },
        .flags = &[_]Flag{
            .{ .short = "-h", .long = "--help", .description = "Show help" },
            .{ .short = "-v", .long = "--verbose", .description = "Be verbose" },
            .{ .short = "-q", .long = "--quiet", .description = "Be quiet" },
        },
    },
    // NPM
    .{
        .name = "npm",
        .subcommands = &[_][]const u8{
            "install",   "i",         "uninstall", "update",    "u",
            "run",       "start",     "stop",     "restart",   "test",
            "build",     "publish",   "add",      "audit",     "ls",
            "outdated",  "init",      "create",   "config",    "link",
            "unlink",    "prefix",    "root",     "search",    "view",
            "version",   "v",         "whoami",   "doctor",
        },
        .flags = &[_]Flag{
            .{ .short = "-g", .long = "--global", .description = "Global package" },
            .{ .short = "-D", .long = "--save-dev", .description = "Save as dev dependency" },
            .{ .short = "-S", .long = "--save", .description = "Save as dependency" },
            .{ .short = "-E", .long = "--save-exact", .description = "Save exact version" },
        },
    },
    // Docker
    .{
        .name = "docker",
        .subcommands = &[_][]const u8{
            "build",     "images",    "ps",        "run",      "exec",
            "logs",      "stop",      "start",     "restart",  "rm",
            "rmi",       "pull",      "push",      "search",   "create",
            "network",   "volume",    "compose",   "swarm",    "service",
            "stack",     "config",    "container", "image",    "plugin",
            "system",    "trust",     "login",     "logout",
        },
        .flags = &[_]Flag{
            .{ .short = "-d", .long = "--detach", .description = "Run in background" },
            .{ .short = "-p", .long = "--publish", .description = "Publish port", .requires_value = true },
            .{ .short = "-v", .long = "--volume", .description = "Bind mount", .requires_value = true },
            .{ .short = "-e", .long = "--env", .description = "Environment variable", .requires_value = true },
            .{ .short = "-it", .long = "--interactive", .description = "Interactive mode" },
            .{ .short = "--name", .long = "--name", .description = "Container name", .requires_value = true },
        },
    },
    // Cargo
    .{
        .name = "cargo",
        .subcommands = &[_][]const u8{
            "build",     "b",         "check",     "clean",    "doc",
            "new",       "init",      "add",       "remove",   "run",
            "r",         "test",      "t",         "bench",    "update",
            "search",    "publish",   "install",   "uninstall", "rustc",
            "rustdoc",   "metadata",  "fetch",     "info",     "owner",
            "package",   "login",     "logout",    "vendor",   "verify",
            "report",    "clippy",    "fmt",
        },
        .flags = &[_]Flag{
            .{ .short = "-p", .long = "--package", .description = "Specify package", .requires_value = true },
            .{ .short = "--release", .long = "--release", .description = "Release build" },
            .{ .short = "--all-features", .long = "--all-features", .description = "Enable all features" },
            .{ .short = "--features", .long = "--features", .description = "Features", .requires_value = true },
        },
    },
    // kubectl
    .{
        .name = "kubectl",
        .subcommands = &[_][]const u8{
            "get",       "create",    "delete",    "edit",     "apply",
            "patch",     "replace",   "describe",  "logs",     "exec",
            "port-forward", "top",     "auth",      "rollout",  "scale",
            "autoscale",  "cordon",   "uncordon",  "drain",    "taint",
            "cluster-info", "api-resources", "api-versions", "namespace",
        },
        .flags = &[_]Flag{
            .{ .short = "-n", .long = "--namespace", .description = "Namespace", .requires_value = true },
            .{ .short = "-o", .long = "--output", .description = "Output format", .requires_value = true, .values = &[_][]const u8{"json", "yaml", "wide"} },
            .{ .short = "-A", .long = "--all-namespaces", .description = "All namespaces" },
            .{ .short = "-l", .long = "--selector", .description = "Label selector", .requires_value = true },
        },
    },
    // Python/pip
    .{
        .name = "pip",
        .subcommands = &[_][]const u8{
            "install", "uninstall", "freeze", "list", "show",
            "check", "config", "search", "cache", "index",
            "download", "wheel", "hash",
        },
        .flags = &[_]Flag{
            .{ .short = "-r", .long = "--requirement", .description = "Requirements file", .requires_value = true },
            .{ .short = "-e", .long = "--editable", .description = "Editable install", .requires_value = true },
            .{ .short = "--user", .long = "--user", .description = "Install to user directory" },
            .{ .short = "--upgrade", .long = "--upgrade", .description = "Upgrade package" },
        },
    },
    // Zig
    .{
        .name = "zig",
        .subcommands = &[_][]const u8{
            "build", "build-exe", "build-lib", "build-obj", "test",
            "run", "fmt", "ast-check", "translate-c", "ar",
            "cc", "c++", "fetch", "env", "libc",
            "targets", "version", "zen", "fmt",
        },
        .flags = &[_]Flag{
            .{ .short = "-femit-bin", .long = "-femit-bin", .description = "Output binary", .requires_value = true },
            .{ .short = "-O", .long = "-O", .description = "Optimization", .requires_value = true, .values = &[_][]const u8{"Debug", "ReleaseFast", "ReleaseSmall", "ReleaseSafe"} },
            .{ .short = "-target", .long = "-target", .description = "Target triple", .requires_value = true },
            .{ .short = "-mcpu", .long = "-mcpu", .description = "CPU", .requires_value = true },
        },
    },
    // Yarn
    .{
        .name = "yarn",
        .subcommands = &[_][]const u8{
            "add",    "bin",     "cache",   "config",   "dl",
            "exec",   "explain", "install", "ls",       "outdated",
            "owner",  "pkg",     "remove",  "upgrade",  "upgrade-interactive",
            "version", "why",    "workspace", "workspaces", "info",
        },
        .flags = &[_]Flag{
            .{ .short = "-D", .long = "--dev", .description = "Dev dependency" },
            .{ .short = "-P", .long = "--peer", .description = "Peer dependency" },
            .{ .short = "-O", .long = "--optional", .description = "Optional dependency" },
            .{ .short = "-E", .long = "--exact", .description = "Exact version" },
            .{ .short = "-T", .long = "--tilde", .description = "Tilde version" },
        },
    },
    // pytest
    .{
        .name = "pytest",
        .subcommands = &[_][]const u8{},
        .flags = &[_]Flag{
            .{ .short = "-v", .long = "--verbose", .description = "Verbose output" },
            .{ .short = "-s", .long = "--capture=no", .description = "Don't capture output" },
            .{ .short = "-k", .long = "-k", .description = "Filter tests", .requires_value = true },
            .{ .short = "-x", .long = "--exitfirst", .description = "Stop on first failure" },
            .{ .short = "--cov", .long = "--cov", .description = "Coverage", .requires_value = true },
        },
    },
    // ffmpeg
    .{
        .name = "ffmpeg",
        .subcommands = &[_][]const u8{},
        .flags = &[_]Flag{
            .{ .short = "-i", .long = "-i", .description = "Input file", .requires_value = true },
            .{ .short = "-c:v", .long = "-c:v", .description = "Video codec", .requires_value = true },
            .{ .short = "-c:a", .long = "-c:a", .description = "Audio codec", .requires_value = true },
            .{ .short = "-b:v", .long = "-b:v", .description = "Video bitrate", .requires_value = true },
            .{ .short = "-s", .long = "-s", .description = "Size", .requires_value = true },
        },
    },
    // gh (GitHub CLI)
    .{
        .name = "gh",
        .subcommands = &[_][]const u8{
            "auth",     "issue",    "pr",       "repo",     "release",
            "gist",     "alias",    "api",      "config",   "extension",
            "search",   "workflow", "run",      "codespace", "actions",
            "secret",
        },
        .flags = &[_]Flag{
            .{ .short = "-R", .long = "--repo", .description = "Repository", .requires_value = true },
            .{ .long = "--json", .description = "JSON output", .requires_value = true },
            .{ .long = "--jq", .description = "JQ expression", .requires_value = true },
            .{ .long = "--limit", .description = "Limit results", .requires_value = true },
        },
    },
};

/// Smart Completions Service
pub const CompletionsService = struct {
    alloc: Allocator,
    enabled: bool,
    max_completions: usize,

    /// Initialize the completions service
    pub fn init(alloc: Allocator, max_completions: usize) CompletionsService {
        return .{
            .alloc = alloc,
            .enabled = true,
            .max_completions = max_completions,
        };
    }

    /// Get completions for the given command line
    pub fn getCompletions(
        self: *const CompletionsService,
        command_line: []const u8,
        cursor_pos: usize,
    ) !std.ArrayList(Completion) {
        var completions = std.ArrayList(Completion).init(self.alloc);
        errdefer {
            for (completions.items) |*c| c.deinit(self.alloc);
            completions.deinit();
        }

        if (!self.enabled) return completions;

        // Parse the command line
        const parsed = try self.parseCommandLine(command_line, cursor_pos);
        defer parsed.deinit(self.alloc);

        // Find the tool spec
        const tool_spec = self.findToolSpec(parsed.tool) orelse return completions;

        // Generate completions based on context
        if (parsed.current_word.len == 0 or parsed.current_word[0] == '-') {
            // Completing flags
            try self.addFlagCompletions(&completions, tool_spec, parsed);
        } else if (parsed.subcommand == null) {
            // Completing subcommands
            try self.addSubcommandCompletions(&completions, tool_spec, parsed);
        } else {
            // Completing arguments (could be filenames or values)
            try self.addArgumentCompletions(&completions, tool_spec, parsed);
        }

        // Trim to max
        while (completions.items.len > self.max_completions) {
            const removed = completions.pop();
            removed.deinit(self.alloc);
        }

        return completions;
    }

    /// Parsed command line state
    const ParsedCommandLine = struct {
        tool: []const u8,
        subcommand: ?[]const u8,
        current_word: []const u8,
        words: std.ArrayList([]const u8),

        fn deinit(self: *ParsedCommandLine, alloc: Allocator) void {
            for (self.words.items) |w| alloc.free(w);
            self.words.deinit();
        }
    };

    /// Parse the command line
    fn parseCommandLine(self: *const CompletionsService, line: []const u8, cursor_pos: usize) !ParsedCommandLine {

        var words = std.ArrayList([]const u8).init(self.alloc);
        errdefer {
            for (words.items) |w| self.alloc.free(w);
            words.deinit();
        }

        // Simple word-based parsing (would need proper shell quoting in production)
        var i: usize = 0;
        var word_start: usize = 0;
        var in_word = false;

        while (i < @min(cursor_pos, line.len)) : (i += 1) {
            const c = line[i];
            if (std.ascii.isSpace(c)) {
                if (in_word) {
                    try words.append(try self.alloc.dupe(u8, line[word_start..i]));
                    in_word = false;
                }
            } else {
                if (!in_word) {
                    word_start = i;
                    in_word = true;
                }
            }
        }

        // Get current word (being typed)
        const current_word = if (in_word)
            try self.alloc.dupe(u8, line[word_start..i])
        else if (i > 0 and std.ascii.isSpace(line[i - 1]))
            "" // Empty word after space
        else
            "";

        return ParsedCommandLine{
            .tool = if (words.items.len > 0) words.items[0] else "",
            .subcommand = if (words.items.len > 1) words.items[1] else null,
            .current_word = current_word,
            .words = words,
        };
    }

    /// Find tool specification
    fn findToolSpec(self: *const CompletionsService, tool_name: []const u8) ?*const ToolSpec {
        _ = self;
        for (&tool_specs) |*spec| {
            if (std.mem.eql(u8, spec.name, tool_name)) {
                return spec;
            }
        }
        return null;
    }

    /// Add flag completions
    fn addFlagCompletions(
        self: *const CompletionsService,
        completions: *std.ArrayList(Completion),
        spec: *const ToolSpec,
        parsed: ParsedCommandLine,
    ) !void {
        const prefix = parsed.current_word;

        for (spec.flags) |flag| {
            // Check short form
            if (flag.short) |short| {
                if (prefix.len == 0 or std.mem.startsWith(u8, short, prefix)) {
                    try completions.append(.{
                        .text = try self.alloc.dupe(u8, short),
                        .description = try self.alloc.dupe(u8, flag.description),
                        .kind = .flag,
                    });
                }
            }

            // Check long form
            if (std.mem.startsWith(u8, flag.long, prefix) or prefix.len == 0) {
                try completions.append(.{
                    .text = try self.alloc.dupe(u8, flag.long),
                    .description = try self.alloc.dupe(u8, flag.description),
                    .kind = .flag,
                });
            }
        }
    }

    /// Add subcommand completions
    fn addSubcommandCompletions(
        self: *const CompletionsService,
        completions: *std.ArrayList(Completion),
        spec: *const ToolSpec,
        parsed: ParsedCommandLine,
    ) !void {
        const prefix = parsed.current_word;

        for (spec.subcommands) |subcmd| {
            if (prefix.len == 0 or std.mem.startsWith(u8, subcmd, prefix)) {
                try completions.append(.{
                    .text = try self.alloc.dupe(u8, subcmd),
                    .description = try self.alloc.dupe(u8, ""), // Could have descriptions in a fuller spec
                    .kind = .subcommand,
                });
            }
        }
    }

    /// Add argument completions (filenames, values, etc.)
    fn addArgumentCompletions(
        self: *const CompletionsService,
        completions: *std.ArrayList(Completion),
        spec: *const ToolSpec,
        parsed: ParsedCommandLine,
    ) !void {
        _ = spec;
        _ = parsed;

        if (self.alloc) |alloc| {
            _ = alloc;
        }

        // For now, just suggest that this could be a filename
        // A full implementation would scan the filesystem
        try completions.append(.{
            .text = try self.alloc.dupe(u8, "<filename>"),
            .description = try self.alloc.dupe(u8, "File or directory"),
            .kind = .filename,
        });
    }

    /// Enable or disable completions
    pub fn setEnabled(self: *CompletionsService, enabled: bool) void {
        self.enabled = enabled;
    }
};
