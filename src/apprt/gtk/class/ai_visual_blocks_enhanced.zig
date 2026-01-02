//! Enhanced Visual Command Blocks UI
//! Provides Warp-like enhanced visual command blocks with grouping and organization

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

const log = std.log.scoped(.gtk_ghostty_visual_blocks_enhanced);

pub const VisualBlocksEnhancedDialog = extern struct {
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
        blocks_list: ?*gtk.ListView = null,
        blocks_store: ?*gio.ListStore = null,
        group_dropdown: ?*gtk.DropDown = null,
        search_entry: ?*gtk.SearchEntry = null,
        new_group_btn: ?*gtk.Button = null,
        pub var offset: c_int = 0;
    };

    pub const BlockGroupItem = extern struct {
        parent_instance: gobject.Object,
        id: [:0]const u8,
        name: [:0]const u8,
        description: ?[:0]const u8 = null,
        created_at: i64,
        block_count: u32 = 0,

        pub const Parent = gobject.Object;

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &BlockGroupItem.dispose);
            }

            fn dispose(self: *BlockGroupItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                alloc.free(self.id);
                alloc.free(self.name);
                if (self.description) |desc| alloc.free(desc);
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }
        };

        pub const getGObjectType = gobject.ext.defineClass(BlockGroupItem, .{
            .name = "GhosttyBlockGroupItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub fn new(alloc: Allocator, id: []const u8, name: []const u8, description: ?[]const u8) !*BlockGroupItem {
            const self = gobject.ext.newInstance(BlockGroupItem, .{});
            self.id = try alloc.dupeZ(u8, id);
            errdefer alloc.free(self.id);
            self.name = try alloc.dupeZ(u8, name);
            errdefer alloc.free(self.name);
            if (description) |desc| {
                self.description = try alloc.dupeZ(u8, desc);
                errdefer alloc.free(self.description.?);
            }
            self.created_at = std.time.timestamp();
            return self;
        }

        // Note: deinit removed - all cleanup handled by GObject dispose to avoid double-frees
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        fn dispose(self: *Self) callconv(.c) void {
            const priv = getPriv(self);
            if (priv.blocks_store) |store| {
                store.removeAll();
            }
            gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
        }

        pub const as = C.Class.as;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyVisualBlocksEnhancedDialog",
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
        self.as(adw.Window).setTitle("Visual Command Blocks");
        self.as(adw.Window).setDefaultSize(1000, 700);

        // Create groups store
        const store = gio.ListStore.new(BlockGroupItem.getGObjectType());
        priv.blocks_store = store;

        // Create main box
        const main_box = gtk.Box.new(gtk.Orientation.vertical, 12);
        main_box.setMarginStart(12);
        main_box.setMarginEnd(12);
        main_box.setMarginTop(12);
        main_box.setMarginBottom(12);

        // Create toolbar
        const toolbar = gtk.Box.new(gtk.Orientation.horizontal, 12);

        const search_entry = gtk.SearchEntry.new();
        search_entry.setPlaceholderText("Search blocks...");
        search_entry.setHexpand(true);
        _ = search_entry.connectSearchChanged(&onSearchChanged, self);
        priv.search_entry = search_entry;

        const group_store = gio.ListStore.new(gobject.Object.getGObjectType());
        const group_dropdown = gtk.DropDown.new(group_store.as(gio.ListModel), null);
        group_dropdown.setTooltipText("Filter by group");
        _ = group_dropdown.connectNotify("selected", &onGroupChanged, self);
        priv.group_dropdown = group_dropdown;

        const new_group_btn = gtk.Button.new();
        new_group_btn.setIconName("list-add-symbolic");
        new_group_btn.setLabel("New Group");
        _ = new_group_btn.connectClicked(&onNewGroup, self);
        priv.new_group_btn = new_group_btn;

        toolbar.append(search_entry.as(gtk.Widget));
        toolbar.append(group_dropdown.as(gtk.Widget));
        toolbar.append(new_group_btn.as(gtk.Widget));

        // Create list view
        const factory = gtk.SignalListItemFactory.new();
        factory.connectSetup(&setupGroupItem, null);
        factory.connectBind(&bindGroupItem, null);

        const selection = gtk.SingleSelection.new(store.as(gio.ListModel));
        const list_view = gtk.ListView.new(selection.as(gtk.SelectionModel), factory);
        list_view.setSingleClickActivate(true);
        _ = list_view.connectActivate(&onGroupActivated, self);
        priv.blocks_list = list_view;

        // Create scrolled window
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setChild(list_view.as(gtk.Widget));
        scrolled.setVexpand(true);

        main_box.append(toolbar.as(gtk.Widget));
        main_box.append(scrolled.as(gtk.Widget));

        self.as(adw.Window).setContent(main_box.as(gtk.Widget));

        // Load groups
        loadGroups(self);
    }

    fn setupGroupItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const card = gtk.Box.new(gtk.Orientation.vertical, 12);
        card.setMarginStart(12);
        card.setMarginEnd(12);
        card.setMarginTop(8);
        card.setMarginBottom(8);
        card.addCssClass("block-group-card");

        const header_box = gtk.Box.new(gtk.Orientation.horizontal, 12);

        const icon = gtk.Image.new();
        icon.setIconName("view-grid-symbolic");
        icon.setIconSize(gtk.IconSize.large);

        const info_box = gtk.Box.new(gtk.Orientation.vertical, 4);
        info_box.setHexpand(true);
        info_box.setHalign(gtk.Align.start);

        const name_label = gtk.Label.new("");
        name_label.setXalign(0);
        name_label.addCssClass("title-4");

        const desc_label = gtk.Label.new("");
        desc_label.setXalign(0);
        desc_label.addCssClass("dim-label");
        desc_label.setWrap(true);

        const meta_label = gtk.Label.new("");
        meta_label.setXalign(0);
        meta_label.addCssClass("caption");
        meta_label.addCssClass("dim-label");

        info_box.append(name_label.as(gtk.Widget));
        info_box.append(desc_label.as(gtk.Widget));
        info_box.append(meta_label.as(gtk.Widget));

        header_box.append(icon.as(gtk.Widget));
        header_box.append(info_box.as(gtk.Widget));

        card.append(header_box.as(gtk.Widget));

        item.setChild(card.as(gtk.Widget));
    }

    fn bindGroupItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const group_item = @as(*BlockGroupItem, @ptrCast(@alignCast(entry)));
        const card = item.getChild() orelse return;
        const card_widget = card.as(gtk.Box);

        if (card_widget.getFirstChild()) |header_box| {
            if (header_box.as(gtk.Box).getFirstChild()) |icon| {
                if (icon.getNextSibling()) |info_box| {
                    if (info_box.as(gtk.Box).getFirstChild()) |name| {
                        name.as(gtk.Label).setText(group_item.name);
                        if (name.getNextSibling()) |desc| {
                            const desc_text = if (group_item.description) |d| d else "No description";
                            desc.as(gtk.Label).setText(desc_text);
                            if (desc.getNextSibling()) |meta| {
                                var meta_buf: [128]u8 = undefined;
                                const meta_text = std.fmt.bufPrintZ(&meta_buf, "{d} blocks", .{group_item.block_count}) catch "Block group";
                                meta.as(gtk.Label).setText(meta_text);
                            }
                        }
                    }
                }
            }
        }
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        _ = entry;
        _ = self;
        // TODO: Implement search filtering
    }

    fn onGroupChanged(_: *gobject.Object, _: glib.ParamSpec, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Implement group filtering
    }

    fn onNewGroup(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Show dialog to create new group
        log.info("New group clicked", .{});
    }

    fn onGroupActivated(_: *gtk.ListView, position: u32, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.blocks_store) |store| {
            if (store.getItem(position)) |item| {
                const group_item: *BlockGroupItem = @ptrCast(@alignCast(item));
                // TODO: Show group details/blocks
                log.info("Group activated: {s}", .{group_item.name});
            }
        }
    }

    fn loadGroups(_: *Self) void {
        // TODO: Load block groups
        log.info("Loading block groups...", .{});
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).present();
    }
};
