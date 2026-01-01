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

        pub fn new(alloc: Allocator, action: []const u8, shortcut: []const u8, description: []const u8) !*ShortcutItem {
            const self = gobject.ext.newInstance(ShortcutItem, .{});
            // Duplicate strings to own the memory
            self.action = try alloc.dupe(u8, action);
            errdefer alloc.free(self.action);
            self.shortcut = try alloc.dupe(u8, shortcut);
            errdefer alloc.free(self.shortcut);
            self.description = try alloc.dupe(u8, description);
            errdefer alloc.free(self.description);
            return self;
        }

        pub fn deinit(self: *ShortcutItem, alloc: Allocator) void {
            alloc.free(self.action);
            alloc.free(self.shortcut);
            alloc.free(self.description);
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

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyKeyboardShortcutsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

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

        const shortcuts_store = gio.ListStore.new(ShortcutItem.getGObjectType());
        priv.shortcuts_store = shortcuts_store;

        // Create factory for list items
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupShortcutItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindShortcutItem, null, .{});

        // Create selection model
        const selection = gtk.NoSelection.new(shortcuts_store.as(gio.ListModel));

        const shortcuts_list = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
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
            const item = ShortcutItem.new(alloc, shortcut.action, shortcut.shortcut, shortcut.description) catch continue;
            shortcuts_store.append(item.as(gobject.Object));
        }
    }

    fn setupShortcutItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.horizontal, 12);
        box.setMarginStart(8);
        box.setMarginEnd(8);
        box.setMarginTop(4);
        box.setMarginBottom(4);

        const action_label = gtk.Label.new("");
        action_label.setXalign(0);
        action_label.setHexpand(@intFromBool(true));
        box.append(action_label.as(gtk.Widget));

        const shortcut_label = gtk.Label.new("");
        shortcut_label.getStyleContext().addClass("dim-label");
        box.append(shortcut_label.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));
    }

    fn bindShortcutItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const shortcut_item = @as(*ShortcutItem, @ptrCast(entry));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |first| {
            first.as(gtk.Label).setText(shortcut_item.description);
            if (first.getNextSibling()) |second| {
                second.as(gtk.Label).setText(shortcut_item.shortcut);
            }
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
