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

        pub fn new(alloc: Allocator, prompt: []const u8, response: []const u8, timestamp: i64, model: []const u8) !*ChatEntry {
            const self = gobject.ext.newInstance(ChatEntry, .{});
            // Duplicate strings to own the memory
            self.prompt = try alloc.dupe(u8, prompt);
            errdefer alloc.free(self.prompt);
            self.response = try alloc.dupe(u8, response);
            errdefer alloc.free(self.response);
            self.timestamp = timestamp;
            self.model = try alloc.dupe(u8, model);
            errdefer alloc.free(self.model);
            return self;
        }

        pub fn deinit(self: *ChatEntry, alloc: Allocator) void {
            alloc.free(self.prompt);
            alloc.free(self.response);
            alloc.free(self.model);
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
        .name = "GhosttyChatHistorySidebar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        return self.refSink();
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

        // History list with proper model and factory
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setVexpand(@intFromBool(true));
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);

        // Initialize the list store
        const history_store = gio.ListStore.new(ChatEntry.getGObjectType());
        priv.history_store = history_store;

        // Create selection model
        const selection = gtk.NoSelection.new(history_store.as(gio.ListModel));

        // Create factory for list items
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupListItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindListItem, null, .{});

        const list_view = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        priv.history_list = list_view;
        scrolled.setChild(list_view.as(gtk.Widget));
        box.append(scrolled.as(gtk.Widget));

        page.setChild(box.as(gtk.Widget));
        self.as(adw.NavigationView).push(page.as(adw.NavigationPage));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Clean up all ChatEntry items in the store to prevent memory leaks
        if (priv.history_store) |store| {
            const n = store.getNItems();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (store.getItem(i)) |item| {
                    const entry: *ChatEntry = @ptrCast(@alignCast(item));
                    entry.deinit(alloc);
                }
            }
        }

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn setupListItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        // Create a box for each history entry
        const box = gtk.Box.new(gtk.Orientation.vertical, 4);
        box.setMarginStart(8);
        box.setMarginEnd(8);
        box.setMarginTop(4);
        box.setMarginBottom(4);

        const prompt_label = gtk.Label.new("");
        prompt_label.setXalign(0);
        prompt_label.setEllipsize(@intFromEnum(std.c.PANGO_ELLIPSIZE_END));
        box.append(prompt_label.as(gtk.Widget));

        const response_label = gtk.Label.new("");
        response_label.setXalign(0);
        response_label.setEllipsize(@intFromEnum(std.c.PANGO_ELLIPSIZE_END));
        response_label.getStyleContext().addClass("dim-label");
        box.append(response_label.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));
    }

    fn bindListItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const chat_entry = @as(*ChatEntry, @ptrCast(entry));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        // Get labels from box
        if (box_widget.getFirstChild()) |first| {
            first.as(gtk.Label).setText(chat_entry.prompt);
            if (first.getNextSibling()) |second| {
                second.as(gtk.Label).setText(chat_entry.response);
            }
        }
    }

    /// Show the sidebar (NavigationView is embedded, not presented as window)
    pub fn show(self: *Self, _: *Window) void {
        // NavigationView should be embedded in a parent container, not presented as window
        self.as(gtk.Widget).setVisible(@intFromBool(true));
    }
};
