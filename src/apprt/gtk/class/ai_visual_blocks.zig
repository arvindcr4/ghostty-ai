//! Visual Command Blocks UI
//! Provides Warp-like visual blocks for commands with drag-and-drop

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

const log = std.log.scoped(.gtk_ghostty_visual_blocks);

pub const VisualBlocksDialog = extern struct {
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
        add_block_btn: ?*gtk.Button = null,

        pub var offset: c_int = 0;
    };

    pub const BlockItem = extern struct {
        parent_instance: gobject.Object,
        title: [:0]const u8,
        command: [:0]const u8,
        output: ?[:0]const u8 = null,
        status: BlockStatus,
        timestamp: i64,

        pub const Parent = gobject.Object;
        pub const BlockStatus = enum {
            pending,
            running,
            success,
            failed,
        };

        pub const getGObjectType = gobject.ext.defineClass(BlockItem, .{
            .name = "GhosttyBlockItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &BlockItem.dispose);
            }

            fn dispose(self: *BlockItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                alloc.free(self.title);
                alloc.free(self.command);
                if (self.output) |out| alloc.free(out);
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }
        };

        pub fn new(alloc: Allocator, title: []const u8, command: []const u8, status: BlockStatus) !*BlockItem {
            const self = gobject.ext.newInstance(BlockItem, .{});
            self.title = try alloc.dupeZ(u8, title);
            errdefer alloc.free(self.title);
            self.command = try alloc.dupeZ(u8, command);
            errdefer alloc.free(self.command);
            self.status = status;
            self.timestamp = std.time.timestamp();
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

        pub const as = C.Class.as;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyVisualBlocksDialog",
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

        self.as(adw.Window).setTitle("Command Blocks");
        self.as(adw.Window).setDefaultSize(800, 600);

        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        // Header
        const header = gtk.Box.new(gtk.Orientation.horizontal, 12);
        const title = gtk.Label.new("Command Blocks");
        title.getStyleContext().addClass("heading");
        header.append(title.as(gtk.Widget));

        const add_btn = gtk.Button.new();
        add_btn.setLabel("Add Block");
        add_btn.setIconName("list-add-symbolic");
        add_btn.setHalign(gtk.Align.end);
        priv.add_block_btn = add_btn;
        _ = add_btn.connectClicked(&addBlock, self);
        header.append(add_btn.as(gtk.Widget));
        box.append(header.as(gtk.Widget));

        // Blocks list
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setVexpand(@intFromBool(true));
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);

        const blocks_store = gio.ListStore.new(BlockItem.getGObjectType());
        priv.blocks_store = blocks_store;

        const selection = gtk.NoSelection.new(blocks_store.as(gio.ListModel));
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupBlockItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindBlockItem, null, .{});

        const blocks_list = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        priv.blocks_list = blocks_list;
        scrolled.setChild(blocks_list.as(gtk.Widget));
        box.append(scrolled.as(gtk.Widget));

        self.as(adw.Window).setContent(box.as(gtk.Widget));
    }

    fn setupBlockItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const frame = gtk.Frame.new(null);
        frame.setMarginStart(4);
        frame.setMarginEnd(4);
        frame.setMarginTop(4);
        frame.setMarginBottom(4);

        const box = gtk.Box.new(gtk.Orientation.vertical, 8);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        const header_box = gtk.Box.new(gtk.Orientation.horizontal, 8);
        const title_label = gtk.Label.new("");
        title_label.setXalign(0);
        title_label.getStyleContext().addClass("heading");
        header_box.append(title_label.as(gtk.Widget));

        const status_label = gtk.Label.new("");
        status_label.setHalign(gtk.Align.end);
        header_box.append(status_label.as(gtk.Widget));
        box.append(header_box.as(gtk.Widget));

        const command_label = gtk.Label.new("");
        command_label.setXalign(0);
        command_label.getStyleContext().addClass("monospace");
        box.append(command_label.as(gtk.Widget));

        const output_scrolled = gtk.ScrolledWindow.new();
        output_scrolled.setMaxContentHeight(200);
        output_scrolled.setPolicy(gtk.PolicyType.automatic, gtk.PolicyType.automatic);
        const output_view = gtk.TextView.new();
        output_view.setEditable(@intFromBool(false));
        output_view.setMonospace(@intFromBool(true));
        output_scrolled.setChild(output_view.as(gtk.Widget));
        box.append(output_scrolled.as(gtk.Widget));

        frame.setChild(box.as(gtk.Widget));
        item.setChild(frame.as(gtk.Widget));
    }

    fn bindBlockItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const block_item = @as(*BlockItem, @ptrCast(@alignCast(entry)));
        const frame = item.getChild() orelse return;
        const box = frame.as(gtk.Frame).getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |header_box| {
            const header_box_widget = header_box.as(gtk.Box);
            if (header_box_widget.getFirstChild()) |title| {
                title.as(gtk.Label).setText(block_item.title);
                if (title.getNextSibling()) |status| {
                    const status_text = switch (block_item.status) {
                        .pending => "⏳ Pending",
                        .running => "🔄 Running",
                        .success => "✅ Success",
                        .failed => "❌ Failed",
                    };
                    status.as(gtk.Label).setText(status_text);
                }
            }
            if (header_box.getNextSibling()) |command| {
                command.as(gtk.Label).setText(block_item.command);
                if (command.getNextSibling()) |output_scrolled| {
                    if (block_item.output) |output| {
                        const output_scrolled_widget = output_scrolled.as(gtk.ScrolledWindow);
                        const output_view = output_scrolled_widget.getChild() orelse return;
                        const buffer = output_view.as(gtk.TextView).getBuffer();
                        const output_z = std.fmt.allocPrintZ(Application.default().allocator(), "{s}", .{output}) catch return;
                        defer Application.default().allocator().free(output_z);
                        buffer.setText(output_z, -1);
                    }
                }
            }
        }
    }

    fn addBlock(button: *gtk.Button, self: *Self) callconv(.c) void {
        _ = button;
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // TODO: Show dialog to create new block
        const block = BlockItem.new(alloc, "New Block", "echo 'Hello World'", .pending) catch {
            log.err("Failed to create block", .{});
            return;
        };

        if (priv.blocks_store) |store| {
            store.append(block.as(gobject.Object));
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);

        // Just removeAll - GObject dispose on each item handles cleanup
        if (priv.blocks_store) |store| {
            store.removeAll();
        }

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).present();
    }
};
