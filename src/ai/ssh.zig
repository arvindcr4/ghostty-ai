//! AI-Powered SSH Connection Assistant
//!
//! This module provides intelligent SSH connection assistance, including:
//! - Parsing and managing SSH config files
//! - AI-powered connection suggestions based on context
//! - Smart host suggestions and connection string completion
//! - SSH command generation with proper flags

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const AutoHashMap = std.AutoHashMap;

const log = std.log.scoped(.ai_ssh);

/// SSH host entry from ~/.ssh/config
pub const SshHost = struct {
    host: []const u8,
    hostname: []const u8,
    user: []const u8,
    port: u16 = 22,
    identity_file: ?[]const u8 = null,
    options: StringHashMap([]const u8),

    pub fn deinit(self: *const SshHost, alloc: Allocator) void {
        alloc.free(self.host);
        alloc.free(self.hostname);
        alloc.free(self.user);
        if (self.identity_file) |f| alloc.free(f);
        var iter = self.options.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.options.deinit();
    }
};

/// SSH connection history entry
pub const SshHistoryEntry = struct {
    host: []const u8,
    timestamp: i64,
    command: []const u8,
};

/// SSH Connection Assistant
pub const SshAssistant = struct {
    const Self = @This();

    alloc: Allocator,
    known_hosts: StringHashMap(SshHost),
    history: std.ArrayList(SshHistoryEntry),
    config_path: []const u8,
    history_path: []const u8,

    /// Initialize the SSH assistant
    pub fn init(alloc: Allocator) !Self {
        const config_path = try getConfigPath(alloc);
        errdefer alloc.free(config_path);

        const history_path = try getHistoryPath(alloc);
        errdefer alloc.free(history_path);

        return .{
            .alloc = alloc,
            .known_hosts = StringHashMap(SshHost).init(alloc),
            .history = std.ArrayList(SshHistoryEntry).init(alloc),
            .config_path = config_path,
            .history_path = history_path,
        };
    }

    pub fn deinit(self: *Self) void {
        var host_iter = self.known_hosts.iterator();
        while (host_iter.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.known_hosts.deinit();

        for (self.history.items) |*entry| {
            self.alloc.free(entry.host);
            self.alloc.free(entry.command);
        }
        self.history.deinit();

        self.alloc.free(self.config_path);
        self.alloc.free(self.history_path);
    }

    /// Load SSH config from ~/.ssh/config
    pub fn loadConfig(self: *Self) !void {
        const file = std.fs.openFileAbsolute(self.config_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        var buf: [8192]u8 = undefined;
        const content = file.readAll(&buf) catch return;

        try self.parseConfig(content);
    }

    /// Parse SSH config content
    fn parseConfig(self: *Self, content: []const u8) !void {
        var current_host: ?SshHost = null;
        var line_iter = std.mem.tokenizeScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.ascii.startsWithIgnoreCase(trimmed, "Host ")) {
                if (current_host) |*host| {
                    try self.known_hosts.put(try self.alloc.dupe(u8, host.host), host.*);
                }

                const host_pattern = trimmed[5..];
                current_host = .{
                    .host = try self.alloc.dupe(u8, host_pattern),
                    .hostname = host_pattern,
                    .user = "",
                    .port = 22,
                    .options = StringHashMap([]const u8).init(self.alloc),
                };
            } else if (current_host) |*host| {
                if (std.ascii.startsWithIgnoreCase(trimmed, "Hostname ")) {
                    host.hostname = try self.alloc.dupe(u8, trimmed[9..]);
                } else if (std.ascii.startsWithIgnoreCase(trimmed, "User ")) {
                    host.user = try self.alloc.dupe(u8, trimmed[5..]);
                } else if (std.ascii.startsWithIgnoreCase(trimmed, "Port ")) {
                    host.port = std.fmt.parseInt(u16, trimmed[5..], 10) catch 22;
                } else if (std.ascii.startsWithIgnoreCase(trimmed, "IdentityFile ")) {
                    host.identity_file = try self.alloc.dupe(u8, trimmed[14..]);
                } else if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space| {
                    const key = trimmed[0..space];
                    const value = std.mem.trim(u8, trimmed[space + 1..], " \t");
                    try host.options.put(try self.alloc.dupe(u8, key), try self.alloc.dupe(u8, value));
                }
            }
        }

        if (current_host) |*host| {
            try self.known_hosts.put(try self.alloc.dupe(u8, host.host), host.*);
        }
    }

    /// Load connection history
    pub fn loadHistory(self: *Self) !void {
        const file = std.fs.openFileAbsolute(self.history_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer file.close();

        var buf: [16384]u8 = undefined;
        const content = file.readAll(&buf) catch return;

        var line_iter = std.mem.tokenizeScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            if (line.len == 0) continue;
            var parts = std.mem.splitScalar(u8, line, '\t');
            const host = parts.next() orelse continue;
            const timestamp_str = parts.next() orelse continue;
            const command = parts.rest();

            const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch continue;

            try self.history.append(.{
                .host = try self.alloc.dupe(u8, host),
                .timestamp = timestamp,
                .command = try self.alloc.dupe(u8, command),
            });
        }
    }

    /// Save connection history
    pub fn saveHistory(self: *Self) !void {
        const dir = std.fs.path.dirname(self.history_path) orelse ".";
        std.fs.makeDirAbsolute(dir) catch {};

        const file = try std.fs.createFileAbsolute(self.history_path, .{ .mode = 0o600 });
        defer file.close();

        var writer = file.writer();
        for (self.history.items) |entry| {
            try writer.print("{s}\t{d}\t{s}\n", .{
                entry.host,
                entry.timestamp,
                entry.command,
            });
        }
    }

    /// Record a connection
    pub fn recordConnection(self: *Self, host: []const u8, command: []const u8) !void {
        // Remove old entries for same host
        var i: usize = 0;
        while (i < self.history.items.len) {
            if (std.mem.eql(u8, self.history.items[i].host, host)) {
                self.alloc.free(self.history.items[i].host);
                self.alloc.free(self.history.items[i].command);
                _ = self.history.swapRemove(i);
            } else {
                i += 1;
            }
        }

        // Add new entry
        try self.history.append(.{
            .host = try self.alloc.dupe(u8, host),
            .timestamp = std.time.timestamp(),
            .command = try self.alloc.dupe(u8, command),
        });

        // Keep only last 50 entries
        if (self.history.items.len > 50) {
            const to_remove = self.history.items.len - 50;
            for (0..to_remove) |idx| {
                self.alloc.free(self.history.items[idx].host);
                self.alloc.free(self.history.items[idx].command);
            }
            std.mem.rotate(SshHistoryEntry, self.history.items, to_remove);
            self.history.shrinkRetainingCapacity(50);
        }

        try self.saveHistory();
    }

    /// Get matching hosts for a prefix
    pub fn getMatchingHosts(self: *Self, prefix: []const u8) ![][]const u8 {
        var matches = std.ArrayList([]const u8).init(self.alloc);
        errdefer matches.deinit();

        var iter = self.known_hosts.iterator();
        while (iter.next()) |entry| {
            if (std.ascii.startsWithIgnoreCase(entry.key_ptr.*, prefix)) {
                try matches.append(entry.key_ptr.*);
            }
        }

        // Sort by history usage
        const SortContext = struct {
            history: *const std.ArrayList(SshHistoryEntry),
            fn less(ctx: @This(), a: []const u8, b: []const u8) bool {
                var a_score: i64 = 0;
                var b_score: i64 = 0;
                for (ctx.history.items) |entry| {
                    if (std.mem.eql(u8, entry.host, a)) a_score = entry.timestamp;
                    if (std.mem.eql(u8, entry.host, b)) b_score = entry.timestamp;
                }
                return a_score > b_score;
            }
        };

        std.sort.insertionSort([]const u8, matches.items, SortContext{ .history = &self.history });

        return matches.toOwnedSlice();
    }

    /// Generate SSH command with AI assistance
    pub fn generateSshCommand(
        self: *Self,
        host: []const u8,
        options: []const []const u8,
    ) ![]const u8 {
        const ssh_host = self.known_hosts.get(host);
        const hostname = if (ssh_host) |h| h.hostname else host;
        const user = if (ssh_host) |h| h.user else "";
        const port = if (ssh_host) |h| h.port else 22;

        var args = std.ArrayList([]const u8).init(self.alloc);
        defer args.deinit();

        try args.append("ssh");

        if (!std.mem.eql(u8, user, "")) {
            try args.append(try std.fmt.allocPrint(self.alloc, "{s}@{s}", .{ user, hostname }));
        } else {
            try args.append(hostname);
        }

        if (port != 22) {
            try args.append(try std.fmt.allocPrint(self.alloc, "-p {d}", .{port}));
        }

        for (options) |opt| {
            try args.append(opt);
        }

        if (ssh_host) |h| {
            if (h.identity_file) |id_file| {
                try args.append(try std.fmt.allocPrint(self.alloc, "-i {s}", .{id_file}));
            }
        }

        return try std.mem.join(self.alloc, " ", args.items);
    }

    /// AI-powered connection suggestion
    pub fn suggestConnection(
        self: *Self,
        context: []const u8,
        ai_client: anytype,
    ) ![]const u8 {
        // Get recent connections for context
        var recent_hosts = std.ArrayList([]const u8).init(self.alloc);
        defer recent_hosts.deinit();

        const now = std.time.timestamp();
        const one_week_ago = now - 7 * 24 * 60 * 60;

        var iter = self.history.iterator();
        while (iter.next()) |entry| {
            if (entry.timestamp > one_week_ago) {
                try recent_hosts.append(entry.host);
            }
        }

        const recent_str = try std.mem.join(self.alloc, ", ", recent_hosts.items);

        const prompt = try std.fmt.allocPrint(self.alloc,
            \\Based on the following terminal context, suggest an SSH connection:
            \\
            \\Context:
            \\{s}
            \\
            \\Recently used hosts: {s}
            \\
            \\Known SSH hosts: {s}
            \\
            \\Provide a concise suggestion in one of these formats:
            \\- Just the host name if it matches a known host
            \\- A full ssh command if you can construct one
            \\- A question if you need more information
            \\
            \\Suggestion:
        , .{
            context,
            recent_str,
            try std.mem.join(self.alloc, ", ", self.known_hosts.keys()),
        });
        defer self.alloc.free(prompt);
        defer self.alloc.free(recent_str);

        const response = try ai_client.chat(
            \\You are an SSH connection assistant. Help users connect to servers efficiently.
        , prompt);

        defer response.deinit(self.alloc);

        return try self.alloc.dupe(u8, response.content);
    }

    /// Get all known hosts
    pub fn getKnownHosts(self: *Self) ![][]const u8 {
        var hosts = std.ArrayList([]const u8).init(self.alloc);
        errdefer hosts.deinit();

        var iter = self.known_hosts.iterator();
        while (iter.next()) |entry| {
            try hosts.append(entry.key_ptr.*);
        }

        return hosts.toOwnedSlice();
    }

    /// Get host details
    pub fn getHostDetails(self: *Self, host: []const u8) ?SshHost {
        return self.known_hosts.get(host);
    }
};

/// Get SSH config path
fn getConfigPath(alloc: Allocator) ![]const u8 {
    const home = std.os.getenv("HOME") orelse return error.NoHomeDirectory;
    return try std.fs.path.join(alloc, &.{ home, ".ssh", "config" });
}

/// Get history path
fn getHistoryPath(alloc: Allocator) ![]const u8 {
    const xdg_state = std.os.getenv("XDG_STATE_HOME") orelse ".local/state";
    const home = std.os.getenv("HOME") orelse return error.NoHomeDirectory;
    const base = if (std.os.getenv("XDG_STATE_HOME") != null) xdg_state else ".local/state";
    return try std.fs.path.join(alloc, &.{ home, base, "ghostty", "ssh_history" });
}

/// Parse SSH URL to extract components
pub fn parseSshUrl(url: []const u8) !struct { user: ?[]const u8, host: []const u8, port: ?u16, path: ?[]const u8 } {
    // ssh://[user@]host[:port][/path]
    const prefix = "ssh://";
    var remaining = url;

    if (std.ascii.startsWithIgnoreCase(url, prefix)) {
        remaining = url[prefix.len..];
    }

    const at_idx = std.mem.indexOfScalar(u8, remaining, '@');
    const colon_idx = std.mem.indexOfScalar(u8, remaining, ':');
    const slash_idx = std.mem.indexOfScalar(u8, remaining, '/');

    var user: ?[]const u8 = null;
    var host_start: usize = 0;

    if (at_idx) |idx| {
        user = remaining[0..idx];
        host_start = idx + 1;
    }

    var host_end = remaining.len;
    var port: ?u16 = null;

    if (colon_idx) |idx| {
        if (idx >= host_start) {
            host_end = idx;
            const port_str = if (slash_idx) |s| remaining[idx + 1..s] else remaining[idx + 1..];
            port = std.fmt.parseInt(u16, port_str, 10) catch null;
        }
    } else if (slash_idx) |idx| {
        host_end = idx;
    }

    if (host_end < host_start) host_end = host_start;

    const path = if (slash_idx) |idx| std.mem.trim(u8, remaining[idx..], "/") else null;

    return .{
        .user = user,
        .host = try std.alloc.dupeZ(u8, std.heap.page_allocator, remaining[host_start..host_end]),
        .port = port,
        .path = path,
    };
}

test "parse SSH URL" {
    const result = try parseSshUrl("ssh://user@host.example.com:2222/path");
    try std.testing.expectEqualStrings("user", result.user.?);
    try std.testing.expectEqualStrings("host.example.com", result.host);
    try std.testing.expectEqual(@as(u16, 2222), result.port.?);
}

test "parse SSH URL without port" {
    const result = try parseSshUrl("user@host.example.com/path");
    try std.testing.expectEqualStrings("user", result.user.?);
    try std.testing.expectEqualStrings("host.example.com", result.host);
    try std.testing.expect(null == result.port);
}
