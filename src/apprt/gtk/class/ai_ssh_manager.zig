//! SSH Connection Manager UI
//! Provides Warp-like UI for managing SSH connections

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

const log = std.log.scoped(.gtk_ghostty_ssh_manager);

pub const SshManagerDialog = extern struct {
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
        connections_list: ?*gtk.ListView = null,
        connections_store: ?*gio.ListStore = null,
        search_entry: ?*gtk.SearchEntry = null,
        add_btn: ?*gtk.Button = null,
        pub var offset: c_int = 0;
    };

    pub const SshConnectionItem = extern struct {
        parent_instance: gobject.Object,
        name: [:0]const u8,
        host: [:0]const u8,
        port: u16,
        username: [:0]const u8,
        key_file: ?[:0]const u8 = null,
        last_used: ?i64 = null,

        pub const Parent = gobject.Object;

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &SshConnectionItem.dispose);
            }

            fn dispose(self: *SshConnectionItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                alloc.free(self.name);
                alloc.free(self.host);
                alloc.free(self.username);
                if (self.key_file) |key| alloc.free(key);
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }
        };

        pub const getGObjectType = gobject.ext.defineClass(SshConnectionItem, .{
            .name = "GhosttySshConnectionItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub fn new(alloc: Allocator, name: []const u8, host: []const u8, port: u16, username: []const u8, key_file: ?[]const u8) !*SshConnectionItem {
            const self = gobject.ext.newInstance(SshConnectionItem, .{});
            self.name = try alloc.dupeZ(u8, name);
            errdefer alloc.free(self.name);
            self.host = try alloc.dupeZ(u8, host);
            errdefer alloc.free(self.host);
            self.port = port;
            self.username = try alloc.dupeZ(u8, username);
            errdefer alloc.free(self.username);
            if (key_file) |key| {
                self.key_file = try alloc.dupeZ(u8, key);
                errdefer alloc.free(self.key_file.?);
            }
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
            if (priv.connections_store) |store| {
                store.removeAll();
            }
            gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
        }

        pub const as = C.Class.as;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySshManagerDialog",
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
        self.as(adw.PreferencesWindow).setTitle("SSH Connections");

        // Create connections store
        const store = gio.ListStore.new(SshConnectionItem.getGObjectType());
        priv.connections_store = store;

        // Create search entry
        const search_entry = gtk.SearchEntry.new();
        search_entry.setPlaceholderText("Search connections...");
        _ = search_entry.connectSearchChanged(&onSearchChanged, self);
        priv.search_entry = search_entry;

        // Create add button
        const add_btn = gtk.Button.new();
        add_btn.setIconName("list-add-symbolic");
        add_btn.setTooltipText("Add Connection");
        _ = add_btn.connectClicked(&onAddConnection, self);
        priv.add_btn = add_btn;

        // Create list view
        const factory = gtk.SignalListItemFactory.new();
        factory.connectSetup(&setupConnectionItem, null);
        factory.connectBind(&bindConnectionItem, null);

        const selection = gtk.SingleSelection.new(store.as(gio.ListModel));
        const list_view = gtk.ListView.new(selection.as(gtk.SelectionModel), factory);
        list_view.setSingleClickActivate(true);
        _ = list_view.connectActivate(&onConnectionActivated, self);
        priv.connections_list = list_view;

        // Create scrolled window
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setChild(list_view.as(gtk.Widget));
        scrolled.setVexpand(true);

        // Create header bar
        const header = adw.HeaderBar.new();
        header.setTitleWidget(gtk.Label.new("SSH Connections"));
        header.packStart(search_entry.as(gtk.Widget));
        header.packEnd(add_btn.as(gtk.Widget));

        // Create main page
        const page = adw.PreferencesPage.new();
        page.setIconName("network-server-symbolic");
        page.setTitle("SSH");

        const group = adw.PreferencesGroup.new();
        group.setTitle("SSH Connections");
        group.setDescription("Manage SSH connections for remote terminal access");
        group.add(scrolled.as(gtk.Widget));

        page.add(group.as(gtk.Widget));
        self.as(adw.PreferencesWindow).add(page.as(gtk.Widget));

        // Load connections
        loadConnections(self);
    }

    fn setupConnectionItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.horizontal, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(6);
        box.setMarginBottom(6);

        const icon = gtk.Image.new();
        icon.setIconName("network-server-symbolic");
        icon.setIconSize(gtk.IconSize.large);

        const info_box = gtk.Box.new(gtk.Orientation.vertical, 4);
        info_box.setHexpand(true);
        info_box.setHalign(gtk.Align.start);

        const name_label = gtk.Label.new("");
        name_label.setXalign(0);
        name_label.addCssClass("title-4");

        const host_label = gtk.Label.new("");
        host_label.setXalign(0);
        host_label.addCssClass("monospace");
        host_label.addCssClass("dim-label");

        const meta_label = gtk.Label.new("");
        meta_label.setXalign(0);
        meta_label.addCssClass("caption");
        meta_label.addCssClass("dim-label");

        info_box.append(name_label.as(gtk.Widget));
        info_box.append(host_label.as(gtk.Widget));
        info_box.append(meta_label.as(gtk.Widget));

        const action_box = gtk.Box.new(gtk.Orientation.horizontal, 4);
        const connect_btn = gtk.Button.new();
        connect_btn.setIconName("network-workgroup-symbolic");
        connect_btn.setTooltipText("Connect");
        connect_btn.addCssClass("circular");
        connect_btn.addCssClass("flat");
        connect_btn.addCssClass("suggested-action");

        const edit_btn = gtk.Button.new();
        edit_btn.setIconName("document-edit-symbolic");
        edit_btn.setTooltipText("Edit");
        edit_btn.addCssClass("circular");
        edit_btn.addCssClass("flat");

        const delete_btn = gtk.Button.new();
        delete_btn.setIconName("user-trash-symbolic");
        delete_btn.setTooltipText("Delete");
        delete_btn.addCssClass("circular");
        delete_btn.addCssClass("flat");
        delete_btn.addCssClass("destructive-action");

        action_box.append(connect_btn.as(gtk.Widget));
        action_box.append(edit_btn.as(gtk.Widget));
        action_box.append(delete_btn.as(gtk.Widget));

        box.append(icon.as(gtk.Widget));
        box.append(info_box.as(gtk.Widget));
        box.append(action_box.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));

        // Connect signal handlers once during setup
        _ = connect_btn.connectClicked(&onConnectListItem, item);
        _ = edit_btn.connectClicked(&onEditConnectionListItem, item);
        _ = delete_btn.connectClicked(&onDeleteConnectionListItem, item);
    }

    fn bindConnectionItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const conn_item = @as(*SshConnectionItem, @ptrCast(@alignCast(entry)));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |icon| {
            if (icon.getNextSibling()) |info_box| {
                if (info_box.as(gtk.Box).getFirstChild()) |name| {
                    name.as(gtk.Label).setText(conn_item.name);
                    if (name.getNextSibling()) |host| {
                        var host_buf: [256]u8 = undefined;
                        const host_text = std.fmt.bufPrintZ(&host_buf, "{s}@{s}:{d}", .{ conn_item.username, conn_item.host, conn_item.port }) catch "SSH Connection";
                        host.as(gtk.Label).setText(host_text);
                        if (host.getNextSibling()) |meta| {
                            var meta_buf: [256]u8 = undefined;
                            const meta_text = if (conn_item.key_file) |key|
                                std.fmt.bufPrintZ(&meta_buf, "Key: {s}", .{key}) catch "SSH"
                            else
                                "Password";
                            meta.as(gtk.Label).setText(meta_text);
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

    fn onAddConnection(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Show dialog to add new connection
        log.info("Add connection clicked", .{});
    }

    fn onConnectionActivated(_: *gtk.ListView, position: u32, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.connections_store) |store| {
            if (store.getItem(position)) |item| {
                const conn_item: *SshConnectionItem = @ptrCast(@alignCast(item));
                // TODO: Connect to SSH
                log.info("Connection activated: {s}", .{conn_item.name});
            }
        }
    }

    fn onConnectListItem(_: *gtk.Button, list_item: *gtk.ListItem) callconv(.c) void {
        const entry = list_item.getItem() orelse return;
        const conn_item = @as(*SshConnectionItem, @ptrCast(@alignCast(entry)));
        // TODO: Connect to SSH
        log.info("Connect to: {s}", .{conn_item.host});
    }

    fn onEditConnectionListItem(_: *gtk.Button, list_item: *gtk.ListItem) callconv(.c) void {
        const entry = list_item.getItem() orelse return;
        const conn_item = @as(*SshConnectionItem, @ptrCast(@alignCast(entry)));
        // TODO: Show edit dialog
        log.info("Edit connection: {s}", .{conn_item.name});
    }

    fn onDeleteConnectionListItem(_: *gtk.Button, list_item: *gtk.ListItem) callconv(.c) void {
        const entry = list_item.getItem() orelse return;
        const conn_item = @as(*SshConnectionItem, @ptrCast(@alignCast(entry)));
        // TODO: Remove from store
        log.info("Delete connection: {s}", .{conn_item.name});
    }

    fn loadConnections(_: *Self) void {
        // TODO: Load connections from SSH config
        log.info("Loading SSH connections...", .{});
    }

    pub fn addConnection(self: *Self, name: []const u8, host: []const u8, port: u16, username: []const u8, key_file: ?[]const u8) !void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        const conn = try SshConnectionItem.new(alloc, name, host, port, username, key_file);
        if (priv.connections_store) |store| {
            store.append(conn.as(gobject.Object));
        }
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.PreferencesWindow).setTransientFor(parent.as(gtk.Window));
        self.as(adw.PreferencesWindow).present();
    }
};
