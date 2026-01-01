//! AI Chat History Sidebar
//! Provides persistent chat history similar to Warp's AI chat

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

const log = std.log.scoped(.gtk_ghostty_chat_history);

pub const ChatHistorySidebar = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.NavigationView;

    const Private = struct {
        history_list: ?*gtk.ListView = null,
        history_store: ?*gio.ListStore = null,
        search_entry: ?*gtk.SearchEntry = null,
        clear_btn: ?*gtk.Button = null,

        pub var offset: c_int = 0;
    };

    pub const ChatEntry = extern struct {
        parent_instance: gobject.Object,
        prompt: []const u8,
        response: []const u8,
        timestamp: i64,
        model: []const u8,

        pub const Parent = gobject.Object;
        pub const getGObjectType = gobject.ext.defineClass(ChatEntry, .{
            .name = "GhosttyChatEntry",
            .classInit = &EntryClass.init,
            .parent_class = &EntryClass.parent,
        });

        pub const EntryClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *EntryClass) callconv(.c) void {
                _ = class;
            }
        };

        pub fn new(prompt: []const u8, response: []const u8, timestamp: i64, model: []const u8) *ChatEntry {
            const self = gobject.ext.newInstance(ChatEntry, .{});
            self.prompt = prompt;
            self.response = response;
            self.timestamp = timestamp;
            self.model = model;
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

        // Create sidebar content
        const page = adw.NavigationPage.new();
        page.setTitle("Chat History");

        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        // Search bar
        const search = gtk.SearchEntry.new();
        search.setPlaceholderText("Search chat history...");
        priv.search_entry = search;
        box.append(search.as(gtk.Widget));

        // Clear button
        const clear = gtk.Button.new();
        clear.setLabel("Clear History");
        clear.setIconName("edit-clear-symbolic");
        priv.clear_btn = clear;
        box.append(clear.as(gtk.Widget));

        // History list
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setVexpand(@intFromBool(true));
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);

        const list_view = gtk.ListView.new(null, null);
        priv.history_list = list_view;
        scrolled.setChild(list_view.as(gtk.Widget));
        box.append(scrolled.as(gtk.Widget));

        page.setChild(box.as(gtk.Widget));
        self.as(adw.NavigationView).push(page.as(adw.NavigationPage));
    }

    fn dispose(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).present();
    }
};
