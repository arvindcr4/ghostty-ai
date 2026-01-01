//! Command Palette UI
//! Provides Warp-like command palette for quick access to AI features

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

const log = std.log.scoped(.gtk_ghostty_command_palette);

pub const CommandPalette = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Window;

    const Private = struct {
        search_entry: ?*gtk.SearchEntry = null,
        command_list: ?*gtk.ListView = null,
        command_store: ?*gio.ListStore = null,
        filtered_store: ?*gtk.FilterListModel = null,
        string_filter: ?*gtk.StringFilter = null,

        pub var offset: c_int = 0;
    };

    pub const CommandItem = extern struct {
        parent_instance: gobject.Object,
        id: []const u8,
        label: []const u8,
        description: []const u8,
        icon: []const u8,
        action: []const u8,
        keywords: []const []const u8,

        pub const Parent = gobject.Object;
        pub const getGObjectType = gobject.ext.defineClass(CommandItem, .{
            .name = "GhosttyCommandItem",
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

        pub fn new(id: []const u8, label: []const u8, description: []const u8, icon: []const u8, action: []const u8) *CommandItem {
            const self = gobject.ext.newInstance(CommandItem, .{});
            self.id = id;
            self.label = label;
            self.description = description;
            self.icon = icon;
            self.action = action;
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

        // Create UI
        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        const title = gtk.Label.new("Command Palette");
        const title_ctx = title.getStyleContext();
        title_ctx.addClass("heading");
        box.append(title.as(gtk.Widget));

        const search = gtk.SearchEntry.new();
        search.setPlaceholderText("Type to search commands...");
        priv.search_entry = search;
        box.append(search.as(gtk.Widget));

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setMinContentHeight(300);
        scrolled.setMaxContentHeight(400);
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);

        const list_view = gtk.ListView.new(null, null);
        priv.command_list = list_view;
        scrolled.setChild(list_view.as(gtk.Widget));
        box.append(scrolled.as(gtk.Widget));

        self.as(adw.Window).setContent(box.as(gtk.Widget));
        self.as(adw.Window).setTitle("Command Palette");
        self.as(adw.Window).setDefaultSize(600, 500);
        self.as(adw.Window).setModal(@intFromBool(true));
    }

    fn dispose(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).present();
    }
};
