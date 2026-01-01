//! Inline Command Suggestions
//! Provides Warp-like inline command suggestions as you type

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

const log = std.log.scoped(.gtk_ghostty_inline_suggestions);

pub const InlineSuggestions = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = gtk.Box;

    const Private = struct {
        suggestions_list: ?*gtk.ListView = null,
        suggestions_store: ?*gio.ListStore = null,
        current_query: ?[]const u8 = null,

        pub var offset: c_int = 0;
    };

    pub const SuggestionItem = extern struct {
        parent_instance: gobject.Object,
        command: []const u8,
        description: []const u8,
        confidence: f32,

        pub const Parent = gobject.Object;
        pub const getGObjectType = gobject.ext.defineClass(SuggestionItem, .{
            .name = "GhosttySuggestionItem",
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

        pub fn new(alloc: Allocator, command: []const u8, description: []const u8, confidence: f32) !*SuggestionItem {
            const self = gobject.ext.newInstance(SuggestionItem, .{});
            self.command = try alloc.dupe(u8, command);
            errdefer alloc.free(self.command);
            self.description = try alloc.dupe(u8, description);
            errdefer alloc.free(self.description);
            self.confidence = confidence;
            return self;
        }

        pub fn deinit(self: *SuggestionItem, alloc: Allocator) void {
            alloc.free(self.command);
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
        .name = "GhosttyInlineSuggestions",
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
        _ = Application.default().allocator();

        self.as(gtk.Box).setOrientation(gtk.Orientation.vertical);
        self.as(gtk.Box).setSpacing(4);
        self.as(gtk.Box).setVisible(@intFromBool(false));

        // Suggestions list
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setMaxContentHeight(200);
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);

        const suggestions_store = gio.ListStore.new(SuggestionItem.getGObjectType());
        priv.suggestions_store = suggestions_store;

        const selection = gtk.SingleSelection.new(suggestions_store.as(gio.ListModel));
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupSuggestionItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindSuggestionItem, null, .{});

        const list_view = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        priv.suggestions_list = list_view;
        scrolled.setChild(list_view.as(gtk.Widget));
        self.as(gtk.Box).append(scrolled.as(gtk.Widget));

        // Connect selection to apply suggestion
        _ = selection.connectSelectedChanged(&onSuggestionSelected, self);
    }

    fn setupSuggestionItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.horizontal, 8);
        box.setMarginStart(8);
        box.setMarginEnd(8);
        box.setMarginTop(2);
        box.setMarginBottom(2);

        const command_label = gtk.Label.new("");
        command_label.setXalign(0);
        command_label.setHexpand(@intFromBool(true));
        command_label.getStyleContext().addClass("monospace");
        box.append(command_label.as(gtk.Widget));

        const desc_label = gtk.Label.new("");
        desc_label.setXalign(0);
        desc_label.getStyleContext().addClass("dim-label");
        box.append(desc_label.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));
    }

    fn bindSuggestionItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const sugg_item = @as(*SuggestionItem, @ptrCast(entry));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |command| {
            command.as(gtk.Label).setText(sugg_item.command);
            if (command.getNextSibling()) |desc| {
                desc.as(gtk.Label).setText(sugg_item.description);
            }
        }
    }

    fn onSuggestionSelected(selection: *gtk.SingleSelection, self: *Self) callconv(.c) void {
        _ = selection;
        _ = self;
        // TODO: Emit signal or call callback to apply suggestion
        // This will be implemented when integrating with the input view
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Clean up query string
        if (priv.current_query) |query| {
            alloc.free(query);
            priv.current_query = null;
        }

        // Clean up all suggestion items
        if (priv.suggestions_store) |store| {
            const n = store.getNItems();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (store.getItem(i)) |item| {
                    const sugg_item: *SuggestionItem = @ptrCast(@alignCast(item));
                    sugg_item.deinit(alloc);
                }
            }
        }

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn updateSuggestions(self: *Self, query: []const u8, suggestions: []const struct { command: []const u8, description: []const u8, confidence: f32 }) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Clear existing suggestions
        if (priv.suggestions_store) |store| {
            const n = store.getNItems();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (store.getItem(i)) |item| {
                    const sugg_item: *SuggestionItem = @ptrCast(@alignCast(item));
                    sugg_item.deinit(alloc);
                }
            }
            store.removeAll();
        }

        // Update query
        if (priv.current_query) |old_query| {
            alloc.free(old_query);
        }
        priv.current_query = alloc.dupe(u8, query) catch null;

        // Add new suggestions
        if (priv.suggestions_store) |store| {
            for (suggestions) |sugg| {
                const item = SuggestionItem.new(alloc, sugg.command, sugg.description, sugg.confidence) catch continue;
                store.append(item.as(gobject.Object));
            }
        }

        // Show/hide based on whether we have suggestions
        self.as(gtk.Box).setVisible(@intFromBool(suggestions.len > 0));
    }

    pub fn clear(self: *Self) void {
        const priv = getPriv(self);
        if (priv.suggestions_store) |store| {
            store.removeAll();
        }
        self.as(gtk.Box).setVisible(@intFromBool(false));
    }
};
