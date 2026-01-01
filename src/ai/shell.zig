//! Shell Detection and Context for AI
//!
//! This module detects the current shell and provides shell-specific
//! context for AI command generation.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Supported shell types
pub const Shell = enum(u8) {
    bash,
    zsh,
    fish,
    nushell,
    pwsh,
    cmd,
    sh,
    unknown,

    pub fn str(self: Shell) []const u8 {
        return switch (self) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .nushell => "nushell",
            .pwsh => "pwsh",
            .cmd => "cmd",
            .sh => "sh",
            .unknown => "unknown",
        };
    }
};

/// Shell context information
pub const ShellContext = struct {
    shell: Shell,
    shell_path: ?[]const u8,
    version: ?[]const u8,
    aliases: std.StringHashMap([]const u8),
    functions: std.StringHashMap([]const u8),
    prompt: ?[]const u8,

    pub fn init(alloc: Allocator) ShellContext {
        return .{
            .shell = .unknown,
            .shell_path = null,
            .version = null,
            .aliases = std.StringHashMap([]const u8).init(alloc),
            .functions = std.StringHashMap([]const u8).init(alloc),
            .prompt = null,
        };
    }

    pub fn deinit(self: *const ShellContext, alloc: Allocator) void {
        if (self.shell_path) |p| alloc.free(p);
        if (self.version) |v| alloc.free(v);
        if (self.prompt) |p| alloc.free(p);

        var iter = self.aliases.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.aliases.deinit();

        var iter2 = self.functions.iterator();
        while (iter2.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.functions.deinit();
    }
};

/// Detect the current shell from environment and process
pub fn detectShell(alloc: Allocator) !Shell {
    // Try SHELL environment variable first
    if (std.posix.getenv("SHELL")) |shell_path| {
        const basename = std.fs.path.basename(shell_path);

        if (std.mem.indexOf(u8, basename, "bash") != null) return .bash;
        if (std.mem.indexOf(u8, basename, "zsh") != null) return .zsh;
        if (std.mem.indexOf(u8, basename, "fish") != null) return .fish;
        if (std.mem.indexOf(u8, basename, "nu") != null) return .nushell;
        if (std.mem.indexOf(u8, basename, "pwsh") != null or
            std.mem.indexOf(u8, basename, "powershell") != null) return .pwsh;
        if (std.mem.indexOf(u8, basename, "cmd.exe") != null) return .cmd;
        if (std.mem.indexOf(u8, basename, "sh") != null) return .sh;
    }

    // Try to detect from process name (platform-specific)
    if (comptime builtin.os.tag == .linux) {
        // Read /proc/{pid}/comm
        if (std.fs.openFileAbsolute("/proc/self/comm", .{})) |file| {
            defer file.close();
            const comm = file.readToEndAlloc(alloc, 256) catch "";
            defer alloc.free(comm);

            if (std.mem.eql(u8, comm, "bash\n")) return .bash;
            if (std.mem.eql(u8, comm, "zsh\n")) return .zsh;
            if (std.mem.eql(u8, comm, "fish\n")) return .fish;
        } else |_| {}
    } else if (comptime builtin.os.tag == .macos) {
        // On macOS, we could check the parent process
    }

    return .unknown;
}

/// Get shell-specific prompt template
pub fn getShellPrompt(shell: Shell) []const u8 {
    return switch (shell) {
        .bash =>
        \\You are generating commands for bash. Use bash-specific syntax:
        \\- Arrays: arr=(item1 item2); echo ${arr[0]}
        \\- Tests: [[ -f file.txt ]] && echo "exists"
        \\- String manipulation: ${var%.txt}.log
        \\- Avoid using fish/nushell-specific syntax.
        ,
        .zsh =>
        \\You are generating commands for zsh. Use zsh-specific syntax:
        \\- Arrays: arr=(item1 item2); echo $arr[1]
        \\- Global aliases: alias -g name=value
        \\- String manipulation: ${var%.txt}.log
        \\- Zsh-specific globs and modifiers are okay.
        ,
        .fish =>
        \\You are generating commands for fish shell. Use fish-specific syntax:
        \\- Variables: set var value
        \\- Arrays: set arr item1 item2
        \\- Functions: function func_name; echo $argv[1]; end
        \\- No $var for variables, use $var instead
        \\- Command substitution: (command)
        ,
        .nushell =>
        \\You are generating commands for nushell. Use nushell-specific syntax:
        \\- Variables: let var = value
        \\- Commands are built-in, no external binaries needed for basics
        \\- Use pipes | naturally
        \\- Table output is common
        ,
        .pwsh =>
        \\You are generating commands for PowerShell. Use PowerShell-specific syntax:
        \\- Variables: $var = "value"
        \\- Cmdlets: Get-Process, Get-Service, etc.
        \\- Pipes: | work naturally
        \\- Objects and properties: $obj.Property
        ,
        .cmd =>
        \\You are generating commands for Windows CMD. Use CMD-specific syntax:
        \\- Variables: %VAR%
        \\- Commands: dir, copy, del, etc.
        \\- No Unix-style commands unless specified
        \\- Use & for command chaining: cmd1 & cmd2
        ,
        .sh =>
        \\You are generating commands for POSIX sh. Use portable shell syntax:
        \\- Avoid bashisms (no [[ ]], no arrays)
        \\- Use [ test ] for tests
        \\- Use $(command) for command substitution
        \\- Keep it simple and portable
        ,
        .unknown =>
        \\Generate commands that work across most shells.
        \\Prefer POSIX-compliant syntax.
        \\Avoid shell-specific features unless necessary.
        ,
    };
}

/// Convert a command from one shell syntax to another
pub const ConversionError = error{
    UnsupportedShell,
    UnsupportedConversion,
    ParseError,
};

pub fn convertCommand(
    alloc: Allocator,
    command: []const u8,
    from: Shell,
    to: Shell,
) ![]const u8 {
    if (from == to) return alloc.dupe(u8, command);

    // Simple conversions for common patterns
    // A full implementation would parse the AST and convert

    var result = std.ArrayList(u8).init(alloc);
    errdefer result.deinit();

    if (from == .bash and to == .fish) {
        // bash → fish conversions
        const converted = try convertBashToFish(alloc, command);
        defer alloc.free(converted);
        try result.appendSlice(converted);
    } else if (from == .fish and to == .bash) {
        // fish → bash conversions
        const converted = try convertFishToBash(alloc, command);
        defer alloc.free(converted);
        try result.appendSlice(converted);
    } else {
        // For other conversions, just return the original
        // (full implementation would parse and convert)
        try result.appendSlice(command);
    }

    return result.toOwnedSlice();
}

fn convertBashToFish(alloc: Allocator, cmd: []const u8) ![]const u8 {
    // Simple bash → fish conversions
    // $VAR → $VAR
    // ${VAR} → $VAR
    // [[ test ]] → test
    // $(cmd) → (cmd)

    var result = std.ArrayList(u8).init(alloc);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < cmd.len) {
        // Convert $VAR or ${VAR} to $VAR
        if (cmd[i] == '$') {
            const start = i;
            i += 1;

            // Skip { if present
            if (i < cmd.len and cmd[i] == '{') {
                i += 1;
            }

            // Extract variable name
            while (i < cmd.len and (std.ascii.isAlphanumeric(cmd[i]) or cmd[i] == '_')) {
                i += 1;
            }

            // Skip closing }
            if (i < cmd.len and cmd[i] == '}') {
                i += 1;
            }

            try result.append('$');
            try result.appendSlice(cmd[start + 1 .. i]);
        } else if (cmd[i] == '`') {
            // Convert `cmd` to (cmd)
            try result.append('(');
            i += 1;
            while (i < cmd.len and cmd[i] != '`') {
                try result.appendByte(cmd[i]);
                i += 1;
            }
            i += 1; // skip closing `
            try result.append(')');
        } else {
            try result.appendByte(cmd[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

fn convertFishToBash(alloc: Allocator, cmd: []const u8) ![]const u8 {
    // Simple fish → bash conversions
    // $VAR → ${VAR} (for safety in bash)
    // (cmd) → $(cmd)
    // set var val → VAR=val

    var result = std.ArrayList(u8).init(alloc);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < cmd.len) {
        // Convert $VAR to ${VAR}
        if (cmd[i] == '$') {
            try result.writeAll("${");
            i += 1;

            // Extract variable name
            while (i < cmd.len and (std.ascii.isAlphanumeric(cmd[i]) or cmd[i] == '_')) {
                try result.appendByte(cmd[i]);
                i += 1;
            }

            try result.writeAll("}");
        } else if (cmd[i] == '(' and i + 1 < cmd.len and cmd[i + 1] != '(') {
            // Convert (cmd) to $(cmd)
            try result.append('$');
            try result.append('(');
            i += 1;

            while (i < cmd.len and cmd[i] != ')') {
                try result.appendByte(cmd[i]);
                i += 1;
            }
            i += 1; // skip closing )
            try result.append(')');
        } else {
            try result.appendByte(cmd[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}
