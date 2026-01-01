//! AI Command Search Widget
//!
//! This widget provides natural language command search functionality,
//! similar to Warp Terminal's '#' feature. Users can type natural
//! language queries to find commands from their terminal history.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gtk = @import("gtk");
const gobject = @import("gobject");
const gio = @import("gio");
const adw = @import("adw");
const glib = @import("glib");

const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.ai_command_search);

/// Command suggestion from AI search
pub const CommandSuggestion = extern struct {
    parent_instance: gobject.Object,

    pub const Parent = gobject.Object;

    pub const getGObjectType = gobject.ext.defineClass(@This(), .{
        .name = "GhosttyCommandSuggestion",
        .instanceInit = &suggestionInit,
        .classInit = &SuggestionClass.init,
        .parent_class = &SuggestionClass.parent,
        .private = .{ .Type = SuggestionPrivate, .offset = &SuggestionPrivate.offset },
    });

    pub const SuggestionPrivate = struct {
        command: [:0]const u8 = "",
        explanation: [:0]const u8 = "",
        context: [:0]const u8 = "",

        pub var offset: c_int = 0;
    };

    fn suggestionInit(self: *@This()) callconv(.C) void {
        const priv = gobject.ext.getPriv(self, &SuggestionPrivate.offset);
        priv.* = .{};
    }

    pub const SuggestionClass = struct {
        parent_class: Parent.Class,

        pub var parent: Parent.Class = undefined;

        pub fn init(
            _: *gobject.Class.Type,
            _: ?*anyopaque,
        ) callconv(.C) void {}
    };

    pub fn new(command: [:0]const u8, explanation: [:0]const u8, context: [:0]const u8) *@This() {
        const self = gobject.ext.newInstance(@This(), .{});
        const priv = gobject.ext.getPriv(self, &SuggestionPrivate.offset);
        priv.command = command;
        priv.explanation = explanation;
        priv.context = context;
        return self;
    }
};

/// AI Command Search Widget
pub const AiCommandSearch = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,

    pub const Parent = adw.Bin;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyAiCommandSearch",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        // GTK components
        dialog: ?*adw.Dialog = null,
        search_entry: ?*gtk.Entry = null,
        results_list: ?*gtk.ListView = null,
        results_store: ?*gio.ListStore = null,
        loading_label: ?*gtk.Label = null,
        no_results_label: ?*gtk.Label = null,

        // Search state
        search_pending: bool = false,
        current_query: []const u8 = "",

        pub var offset: c_int = 0;
    };

    pub const Class = struct {
        parent_class: Parent.Class,

        pub var parent: Parent.Class = undefined;

        pub fn init(
            _: *gobject.Class.Type,
            _: ?*anyopaque,
        ) callconv(.C) void {}
    };

    /// Create a new AI command search instance
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self) callconv(.C) void {
        const priv = getPriv(self);
        priv.* = .{};

        // Initialize the widget template if available
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    /// Show the command search dialog
    pub fn show(self: *Self, win: *Window) void {
        const priv = getPriv(self);

        if (priv.dialog) |dialog| {
            dialog.present(win.as(gtk.Widget));

            if (priv.search_entry) |entry| {
                entry.grabFocus();
            }
        }
    }

    /// Hide the dialog
    pub fn hide(self: *Self) void {
        const priv = getPriv(self);
        if (priv.dialog) |dialog| {
            dialog.forceClose();
        }
    }

    /// Set the search query (called from UI)
    pub fn setQuery(self: *Self, query: []const u8) void {
        const priv = getPriv(self);
        priv.current_query = query;

        // Debounce: only search after user stops typing
        if (!priv.search_pending) {
            priv.search_pending = true;
            // For now, just clear the pending flag
            // Full implementation would use glib.timeoutAdd
            priv.search_pending = false;
        }
    }
};
