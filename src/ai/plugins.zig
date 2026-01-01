//! Integration APIs / Plugin System Module
//!
//! This module provides a plugin system for extending AI features.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_plugins);

/// Plugin interface
pub const Plugin = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    description: []const u8,
    hooks: ArrayList(PluginHook),
    enabled: bool,

    pub const PluginHook = struct {
        name: []const u8,
        callback: *const fn (data: []const u8, alloc: Allocator) anyerror![]const u8,
    };

    pub fn deinit(self: *Plugin, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.version);
        alloc.free(self.description);
        for (self.hooks.items) |hook| alloc.free(hook.name);
        self.hooks.deinit();
    }
};

/// Plugin Manager
pub const PluginManager = struct {
    alloc: Allocator,
    plugins: StringHashMap(*Plugin),
    hook_registry: StringHashMap(ArrayList(*Plugin.PluginHook)),

    /// Initialize plugin manager
    pub fn init(alloc: Allocator) PluginManager {
        return .{
            .alloc = alloc,
            .plugins = StringHashMap(*Plugin).init(alloc),
            .hook_registry = StringHashMap(ArrayList(*Plugin.PluginHook)).init(alloc),
        };
    }

    pub fn deinit(self: *PluginManager) void {
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.plugins.deinit();

        var hook_iter = self.hook_registry.iterator();
        while (hook_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.hook_registry.deinit();
    }

    /// Register a plugin
    pub fn registerPlugin(
        self: *PluginManager,
        id: []const u8,
        name: []const u8,
        version: []const u8,
    ) !*Plugin {
        const plugin = try self.alloc.create(Plugin);
        plugin.* = .{
            .id = try self.alloc.dupe(u8, id),
            .name = try self.alloc.dupe(u8, name),
            .version = try self.alloc.dupe(u8, version),
            .description = "",
            .hooks = ArrayList(Plugin.PluginHook).init(self.alloc),
            .enabled = true,
        };

        try self.plugins.put(plugin.id, plugin);
        return plugin;
    }

    /// Register a hook
    pub fn registerHook(
        self: *PluginManager,
        plugin: *Plugin,
        hook_name: []const u8,
        callback: *const fn (data: []const u8, alloc: Allocator) anyerror![]const u8,
    ) !void {
        const hook = Plugin.PluginHook{
            .name = try self.alloc.dupe(u8, hook_name),
            .callback = callback,
        };

        try plugin.hooks.append(hook);

        // Register in hook registry
        if (self.hook_registry.get(hook_name)) |existing_list| {
            try existing_list.append(&plugin.hooks.items[plugin.hooks.items.len - 1]);
        } else {
            var list = ArrayList(*Plugin.PluginHook).init(self.alloc);
            try list.append(&plugin.hooks.items[plugin.hooks.items.len - 1]);
            try self.hook_registry.put(try self.alloc.dupe(u8, hook_name), list);
        }
    }

    /// Call hooks for a given hook name
    pub fn callHooks(
        self: *const PluginManager,
        hook_name: []const u8,
        data: []const u8,
    ) !ArrayList([]const u8) {
        var results = ArrayList([]const u8).init(self.alloc);
        errdefer {
            for (results.items) |r| self.alloc.free(r);
            results.deinit();
        }

        if (self.hook_registry.get(hook_name)) |hooks| {
            for (hooks.items) |hook| {
                if (hook.callback(data, self.alloc)) |result| {
                    try results.append(result);
                } else |_| {
                    // Hook failed, continue with others
                }
            }
        }

        return results;
    }

    /// Enable or disable a plugin
    pub fn setPluginEnabled(self: *PluginManager, plugin_id: []const u8, enabled: bool) void {
        if (self.plugins.get(plugin_id)) |plugin| {
            plugin.enabled = enabled;
        }
    }
};
