//! Keyboard Shortcuts Manager UI
//! Provides UI for managing keyboard shortcuts

const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.gtk_ghostty_keyboard_shortcuts);

pub const KeyboardShortcutsDialog = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.PreferencesWindow;

    const Private = struct {
        shortcuts_list: ?*gtk.ListView = null,
        shortcuts_store: ?*gio.ListStore = null,

        pub var offset: c_int = 0;
    };

    pub const ShortcutItem = extern struct {
        parent_instance: gobject.Object,
        action: []const u8,
        shortcut: []const u8,
        description: []const u8,

        pub const Parent = gobject.Object;
        pub const getGObjectType = gobject.ext.defineClass(ShortcutItem, .{
            .name = "GhosttyShortcutItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                _ = class;
            }
        };

        pub fn new(action: []const u8, shortcut: []const u8, description: []const u8) *ShortcutItem {
            const self = gobject.ext.newInstance(ShortcutItem, .{});
            self.action = action;
            self.shortcut = shortcut;
            self.description = description;
            return self;
        }
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self) callconv(.c) void {
        const priv = getPriv(self);

        self.as(adw.PreferencesWindow).setTitle("Keyboard Shortcuts");
        self.as(adw.PreferencesWindow).setDefaultSize(600, 500);

        const page = adw.PreferencesPage.new();
        page.setTitle("Shortcuts");
        page.setIconName("preferences-desktop-keyboard-symbolic");

        const group = adw.PreferencesGroup.new();
        group.setTitle("AI Shortcuts");
        group.setDescription("Keyboard shortcuts for AI features");

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);

        const shortcuts_store = gio.ListStore.new(gobject.Object);
        priv.shortcuts_store = shortcuts_store;

        const shortcuts_list = gtk.ListView.new(null, null);
        priv.shortcuts_list = shortcuts_list;
        scrolled.setChild(shortcuts_list.as(gtk.Widget));

        group.add(scrolled.as(gtk.Widget));
        page.add(group.as(gtk.Widget));
        self.as(adw.PreferencesWindow).add(page.as(adw.PreferencesPage));

        // Add default shortcuts
        const default_shortcuts = [_]struct {
            action: []const u8,
            shortcut: []const u8,
            description: []const u8,
        }{
            .{ .action = "show-ai-input", .shortcut = "Ctrl+Shift+A", .description = "Open AI input dialog" },
            .{ .action = "show-command-palette", .shortcut = "Ctrl+P", .description = "Show command palette" },
            .{ .action = "toggle-history", .shortcut = "Ctrl+H", .description = "Toggle chat history" },
            .{ .action = "execute-command", .shortcut = "Enter", .description = "Execute selected command" },
        };

        for (default_shortcuts) |shortcut| {
            const item = ShortcutItem.new(shortcut.action, shortcut.shortcut, shortcut.description);
            shortcuts_store.append(item);
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.PreferencesWindow).setTransientFor(parent.as(gtk.Window));
        self.as(adw.PreferencesWindow).present();
    }
};
