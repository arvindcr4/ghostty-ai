//! Custom Prompts Module
//!
//! This module allows users to define custom AI behaviors and prompts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const json = std.json;

const log = std.log.scoped(.ai_custom_prompts);

/// A custom prompt template
pub const CustomPrompt = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    system_prompt: []const u8,
    user_template: []const u8,
    variables: ArrayList([]const u8),
    created_at: i64,
    usage_count: u32,

    pub fn init(alloc: Allocator, id: []const u8, name: []const u8) CustomPrompt {
        return .{
            .id = id,
            .name = name,
            .description = "",
            .system_prompt = "",
            .user_template = "",
            .variables = ArrayList([]const u8).init(alloc),
            .created_at = std.time.timestamp(),
            .usage_count = 0,
        };
    }

    pub fn deinit(self: *CustomPrompt, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.system_prompt);
        alloc.free(self.user_template);
        for (self.variables.items) |var_name| alloc.free(var_name);
        self.variables.deinit();
    }

    /// Format prompt with variables
    pub fn format(self: *const CustomPrompt, alloc: Allocator, vars: std.StringHashMap([]const u8)) ![]const u8 {
        var result = ArrayList(u8).init(alloc);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < self.user_template.len) {
            // Look for {variable} patterns
            if (i + 1 < self.user_template.len and self.user_template[i] == '{') {
                const end = std.mem.indexOfPos(u8, self.user_template, i + 1, "}") orelse {
                    try result.append(self.user_template[i]);
                    i += 1;
                    continue;
                };

                const var_name = self.user_template[i + 1 .. end];
                if (vars.get(var_name)) |value| {
                    try result.appendSlice(value);
                } else {
                    try result.appendSlice(self.user_template[i .. end + 1]);
                }
                i = end + 1;
            } else {
                try result.append(self.user_template[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice();
    }
};

/// Custom Prompt Manager
pub const CustomPromptManager = struct {
    alloc: Allocator,
    prompts: std.StringHashMap(*CustomPrompt),
    storage_path: []const u8,

    /// Initialize custom prompt manager
    pub fn init(alloc: Allocator) !CustomPromptManager {
        const home = std.os.getenv("HOME") orelse return error.HomeNotSet;
        const storage_path = try std.fs.path.join(alloc, &.{ home, ".config", "ghostty", "custom_prompts" });

        std.fs.makeDirAbsolute(storage_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        return CustomPromptManager{
            .alloc = alloc,
            .prompts = std.StringHashMap(*CustomPrompt).init(alloc),
            .storage_path = storage_path,
        };
    }

    pub fn deinit(self: *CustomPromptManager) void {
        var iter = self.prompts.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.prompts.deinit();
        self.alloc.free(self.storage_path);
    }

    /// Create a new custom prompt
    pub fn createPrompt(
        self: *CustomPromptManager,
        name: []const u8,
        system_prompt: []const u8,
        user_template: []const u8,
    ) !*CustomPrompt {
        const id = try std.fmt.allocPrint(self.alloc, "prompt_{d}", .{std.time.timestamp()});
        const prompt = try self.alloc.create(CustomPrompt);
        prompt.* = CustomPrompt.init(self.alloc, id, name);
        prompt.name = try self.alloc.dupe(u8, name);
        prompt.system_prompt = try self.alloc.dupe(u8, system_prompt);
        prompt.user_template = try self.alloc.dupe(u8, user_template);

        // Extract variables from template
        var i: usize = 0;
        while (i < user_template.len) {
            if (i + 1 < user_template.len and user_template[i] == '{') {
                if (std.mem.indexOfPos(u8, user_template, i + 1, "}")) |end| {
                    const var_name = user_template[i + 1 .. end];
                    try prompt.variables.append(try self.alloc.dupe(u8, var_name));
                    i = end + 1;
                    continue;
                }
            }
            i += 1;
        }

        try self.prompts.put(id, prompt);
        return prompt;
    }

    /// Get all prompts
    pub fn getAllPrompts(self: *const CustomPromptManager) !ArrayList(*CustomPrompt) {
        var result = ArrayList(*CustomPrompt).init(self.alloc);
        var iter = self.prompts.iterator();
        while (iter.next()) |entry| {
            try result.append(entry.value_ptr.*);
        }
        return result;
    }
};
