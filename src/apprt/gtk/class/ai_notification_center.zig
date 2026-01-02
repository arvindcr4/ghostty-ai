//! Notification Center
//! Provides Warp-like notification center for AI-related notifications

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

const log = std.log.scoped(.gtk_ghostty_notification_center);

pub const NotificationCenter = extern struct {
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
        notifications_list: ?*gtk.ListView = null,
        notifications_store: ?*gio.ListStore = null,
        clear_btn: ?*gtk.Button = null,

        pub var offset: c_int = 0;
    };

    pub const NotificationItem = extern struct {
        parent_instance: gobject.Object,
        title: [:0]const u8,
        message: [:0]const u8,
        timestamp: i64,
        notification_type: NotificationItem.NotificationType,
        action_label: ?[:0]const u8 = null,
        action_id: ?[:0]const u8 = null,

        pub const Parent = gobject.Object;
        pub const getGObjectType = gobject.ext.defineClass(NotificationItem, .{
            .name = "GhosttyNotificationItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub const NotificationType = enum {
            info,
            success,
            warning,
            err,
        };

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &dispose);
                gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            }

            fn dispose(self: *NotificationItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                if (self.title.len > 0) {
                    alloc.free(self.title);
                    self.title = "";
                }
                if (self.message.len > 0) {
                    alloc.free(self.message);
                    self.message = "";
                }
                if (self.action_label) |label| {
                    alloc.free(label);
                    self.action_label = null;
                }
                if (self.action_id) |id| {
                    alloc.free(id);
                    self.action_id = null;
                }
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }

            fn finalize(self: *NotificationItem) callconv(.c) void {
                gobject.Object.virtual_methods.finalize.call(ItemClass.parent, self);
            }
        };

        pub fn new(alloc: Allocator, title: []const u8, message: []const u8, notification_type: NotificationItem.NotificationType, action_label: ?[]const u8, action_id: ?[]const u8) !*NotificationItem {
            const self = gobject.ext.newInstance(NotificationItem, .{});
            self.title = try alloc.dupeZ(u8, title);
            errdefer alloc.free(self.title);
            self.message = try alloc.dupeZ(u8, message);
            errdefer alloc.free(self.message);
            self.timestamp = std.time.timestamp();
            self.notification_type = notification_type;
            if (action_label) |label| {
                self.action_label = try alloc.dupeZ(u8, label);
                errdefer alloc.free(self.action_label.?);
            }
            if (action_id) |id| {
                self.action_id = try alloc.dupeZ(u8, id);
                errdefer alloc.free(self.action_id.?);
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

            // Clean up all notification items - just removeAll, GObject dispose handles item cleanup
            if (priv.notifications_store) |store| {
                store.removeAll();
            }

            gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
        }

        pub const as = C.Class.as;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyNotificationCenter",
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
        _ = Application.default().allocator();

        self.as(adw.Window).setTitle("Notifications");
        self.as(adw.Window).setDefaultSize(400, 500);

        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        // Header
        const header = gtk.Box.new(gtk.Orientation.horizontal, 12);
        const title = gtk.Label.new("Notifications");
        title.getStyleContext().addClass("heading");
        header.append(title.as(gtk.Widget));

        const clear = gtk.Button.new();
        clear.setLabel("Clear All");
        clear.setIconName("edit-clear-symbolic");
        clear.setHalign(gtk.Align.end);
        priv.clear_btn = clear;
        header.append(clear.as(gtk.Widget));
        box.append(header.as(gtk.Widget));

        // Notifications list
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setVexpand(@intFromBool(true));
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);

        const notifications_store = gio.ListStore.new(NotificationItem.getGObjectType());
        priv.notifications_store = notifications_store;

        const selection = gtk.NoSelection.new(notifications_store.as(gio.ListModel));
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupNotificationItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindNotificationItem, null, .{});

        const list_view = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        priv.notifications_list = list_view;
        scrolled.setChild(list_view.as(gtk.Widget));
        box.append(scrolled.as(gtk.Widget));

        self.as(adw.Window).setContent(box.as(gtk.Widget));

        // Connect clear button
        _ = clear.connectClicked(&clearClicked, self);
    }

    fn setupNotificationItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.vertical, 4);
        box.setMarginStart(8);
        box.setMarginEnd(8);
        box.setMarginTop(4);
        box.setMarginBottom(4);

        const title_label = gtk.Label.new("");
        title_label.setXalign(0);
        title_label.getStyleContext().addClass("heading");
        box.append(title_label.as(gtk.Widget));

        const message_label = gtk.Label.new("");
        message_label.setXalign(0);
        message_label.setWrap(@intFromBool(true));
        box.append(message_label.as(gtk.Widget));

        const timestamp_label = gtk.Label.new("");
        timestamp_label.setXalign(0);
        timestamp_label.getStyleContext().addClass("dim-label");
        box.append(timestamp_label.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));
    }

    fn bindNotificationItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const notif_item = @as(*NotificationItem, @ptrCast(entry));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |title| {
            title.as(gtk.Label).setText(notif_item.title);
            if (title.getNextSibling()) |message| {
                message.as(gtk.Label).setText(notif_item.message);
                if (message.getNextSibling()) |timestamp| {
                    var time_buf: [64]u8 = undefined;
                    const time_str = formatTimestamp(time_buf[0..], notif_item.timestamp);
                    timestamp.as(gtk.Label).setText(time_str);
                }
            }
        }
    }

    fn formatTimestamp(buf: []u8, timestamp: i64) [:0]const u8 {
        // Simple timestamp formatting - could be improved
        const now = std.time.timestamp();
        const diff = now - timestamp;
        if (diff < 60) return "Just now";
        if (diff < 3600) {
            const minutes = diff / 60;
            return std.fmt.bufPrintZ(buf, "{d} minutes ago", .{minutes}) catch "Recently";
        }
        return "Earlier";
    }

    fn clearClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        _ = button;
        const priv = getPriv(self);
        // Just removeAll - GObject dispose handles item cleanup
        if (priv.notifications_store) |store| {
            store.removeAll();
        }
    }

    pub fn addNotification(self: *Self, title: []const u8, message: []const u8, notification_type: NotificationItem.NotificationType, action_label: ?[]const u8, action_id: ?[]const u8) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        const item = NotificationItem.new(alloc, title, message, notification_type, action_label, action_id) catch {
            log.err("Failed to create notification item", .{});
            return;
        };

        if (priv.notifications_store) |store| {
            store.append(item.as(gobject.Object));
        }
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).present();
    }
};
