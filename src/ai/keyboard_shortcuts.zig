//! Keyboard Shortcuts Module
//!
//! This module provides power-user keyboard shortcuts for AI features.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_keyboard_shortcuts);

/// A keyboard shortcut
pub const KeyboardShortcut = struct {
    key: []const u8,
    modifiers: Modifiers,
    action: Action,
    description: []const u8,

    pub const Modifiers = struct {
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false,
        super: bool = false,
    };

    pub const Action = enum {
        open_ai_input,
        execute_command,
        copy_response,
        regenerate_response,
        toggle_agent_mode,
        show_suggestions,
        next_suggestion,
        previous_suggestion,
        accept_suggestion,
        cancel_request,
        switch_model,
        open_history,
        open_workflows,
        custom,
    };

    pub fn deinit(self: *const KeyboardShortcut, alloc: Allocator) void {
        alloc.free(self.key);
        alloc.free(self.description);
    }
};

/// Shortcut Manager
pub const ShortcutManager = struct {
    alloc: Allocator,
    shortcuts: ArrayList(KeyboardShortcut),
    key_map: StringHashMap(*KeyboardShortcut),

    /// Initialize shortcut manager
    pub fn init(alloc: Allocator) ShortcutManager {
        var manager = ShortcutManager{
            .alloc = alloc,
            .shortcuts = ArrayList(KeyboardShortcut).init(alloc),
            .key_map = StringHashMap(*KeyboardShortcut).init(alloc),
        };

        // Register default shortcuts
        manager.registerDefaults() catch {};

        return manager;
    }

    pub fn deinit(self: *ShortcutManager) void {
        for (self.shortcuts.items) |*shortcut| shortcut.deinit(self.alloc);
        self.shortcuts.deinit();
        self.key_map.deinit();
    }

    /// Register default shortcuts
    fn registerDefaults(self: *ShortcutManager) !void {
        const defaults = [_]struct {
            key: []const u8,
            modifiers: KeyboardShortcut.Modifiers,
            action: KeyboardShortcut.Action,
            description: []const u8,
        }{
            .{ .key = "i", .modifiers = .{ .ctrl = true }, .action = .open_ai_input, .description = "Open AI input mode" },
            .{ .key = "Return", .modifiers = .{ .ctrl = true }, .action = .execute_command, .description = "Execute selected command" },
            .{ .key = "c", .modifiers = .{ .ctrl = true, .shift = true }, .action = .copy_response, .description = "Copy AI response" },
            .{ .key = "r", .modifiers = .{ .ctrl = true }, .action = .regenerate_response, .description = "Regenerate response" },
            .{ .key = "a", .modifiers = .{ .ctrl = true, .shift = true }, .action = .toggle_agent_mode, .description = "Toggle agent mode" },
            .{ .key = "Tab", .modifiers = .{}, .action = .accept_suggestion, .description = "Accept suggestion" },
            .{ .key = "Escape", .modifiers = .{}, .action = .cancel_request, .description = "Cancel AI request" },
            .{ .key = "m", .modifiers = .{ .ctrl = true, .shift = true }, .action = .switch_model, .description = "Switch AI model" },
            .{ .key = "h", .modifiers = .{ .ctrl = true, .shift = true }, .action = .open_history, .description = "Open command history" },
            .{ .key = "w", .modifiers = .{ .ctrl = true, .shift = true }, .action = .open_workflows, .description = "Open workflows" },
        };

        for (defaults) |def| {
            try self.registerShortcut(def.key, def.modifiers, def.action, def.description);
        }
    }

    /// Register a shortcut
    pub fn registerShortcut(
        self: *ShortcutManager,
        key: []const u8,
        modifiers: KeyboardShortcut.Modifiers,
        action: KeyboardShortcut.Action,
        description: []const u8,
    ) !void {
        const shortcut = KeyboardShortcut{
            .key = try self.alloc.dupe(u8, key),
            .modifiers = modifiers,
            .action = action,
            .description = try self.alloc.dupe(u8, description),
        };

        try self.shortcuts.append(shortcut);
        const shortcut_ptr = &self.shortcuts.items[self.shortcuts.items.len - 1];

        // Create key string for mapping
        var key_str = ArrayList(u8).init(self.alloc);
        defer key_str.deinit();
        if (modifiers.ctrl) try key_str.appendSlice("Ctrl+");
        if (modifiers.alt) try key_str.appendSlice("Alt+");
        if (modifiers.shift) try key_str.appendSlice("Shift+");
        if (modifiers.super) try key_str.appendSlice("Super+");
        try key_str.appendSlice(key);

        try self.key_map.put(try key_str.toOwnedSlice(), shortcut_ptr);
    }

    /// Find shortcut by key combination
    pub fn findShortcut(
        self: *const ShortcutManager,
        key: []const u8,
        modifiers: KeyboardShortcut.Modifiers,
    ) ?*const KeyboardShortcut {
        var key_str = ArrayList(u8).init(self.alloc);
        defer key_str.deinit();

        if (modifiers.ctrl) key_str.appendSlice("Ctrl+") catch |err| {
            log.warn("Failed to append Ctrl+ modifier: {}", .{err});
            return null;
        };
        if (modifiers.alt) key_str.appendSlice("Alt+") catch |err| {
            log.warn("Failed to append Alt+ modifier: {}", .{err});
            return null;
        };
        if (modifiers.shift) key_str.appendSlice("Shift+") catch |err| {
            log.warn("Failed to append Shift+ modifier: {}", .{err});
            return null;
        };
        if (modifiers.super) key_str.appendSlice("Super+") catch |err| {
            log.warn("Failed to append Super+ modifier: {}", .{err});
            return null;
        };
        key_str.appendSlice(key) catch |err| {
            log.warn("Failed to append key: {}", .{err});
            return null;
        };

        return self.key_map.get(key_str.items) orelse null;
    }

    /// Get all shortcuts
    pub fn getAllShortcuts(self: *const ShortcutManager) []const KeyboardShortcut {
        return self.shortcuts.items;
    }
};
