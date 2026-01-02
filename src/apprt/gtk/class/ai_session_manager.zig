//! Session Manager UI
//! Provides Warp-like UI for managing multiple terminal sessions/tabs

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

const log = std.log.scoped(.gtk_ghostty_session_manager);

pub const SessionManagerDialog = extern struct {
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
        sessions_list: ?*gtk.ListView = null,
        sessions_store: ?*gio.ListStore = null,
        new_session_btn: ?*gtk.Button = null,
        search_entry: ?*gtk.SearchEntry = null,
        pub var offset: c_int = 0;
    };

    pub const SessionItem = extern struct {
        parent_instance: gobject.Object,
        id: [:0]const u8,
        title: [:0]const u8,
        cwd: [:0]const u8,
        shell: [:0]const u8,
        created_at: i64,
        last_used: i64,
        is_active: bool = false,

        pub const Parent = gobject.Object;

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &SessionItem.dispose);
            }

            fn dispose(self: *SessionItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                alloc.free(self.id);
                alloc.free(self.title);
                alloc.free(self.cwd);
                alloc.free(self.shell);
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }
        };

        pub const getGObjectType = gobject.ext.defineClass(SessionItem, .{
            .name = "GhosttySessionItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub fn new(id: []const u8, title: []const u8, cwd: []const u8, shell: []const u8) !*SessionItem {
            const alloc = Application.default().allocator();
            const self = gobject.ext.newInstance(SessionItem, .{});
            errdefer self.unref();
            self.id = try alloc.dupeZ(u8, id);
            errdefer alloc.free(self.id);
            self.title = try alloc.dupeZ(u8, title);
            errdefer alloc.free(self.title);
            self.cwd = try alloc.dupeZ(u8, cwd);
            errdefer alloc.free(self.cwd);
            self.shell = try alloc.dupeZ(u8, shell);
            self.created_at = std.time.timestamp();
            self.last_used = std.time.timestamp();
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
            if (priv.sessions_store) |store| {
                store.removeAll();
            }
            gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
        }

        pub const as = C.Class.as;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySessionManagerDialog",
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
        self.as(adw.PreferencesWindow).setTitle("Session Manager");

        // Create sessions store
        const store = gio.ListStore.new(SessionItem.getGObjectType());
        priv.sessions_store = store;

        // Create search entry
        const search_entry = gtk.SearchEntry.new();
        search_entry.setPlaceholderText("Search sessions...");
        _ = search_entry.connectSearchChanged(&onSearchChanged, self);
        priv.search_entry = search_entry;

        // Create new session button
        const new_session_btn = gtk.Button.new();
        new_session_btn.setIconName("list-add-symbolic");
        new_session_btn.setLabel("New Session");
        new_session_btn.setTooltipText("Create New Session");
        new_session_btn.addCssClass("suggested-action");
        _ = new_session_btn.connectClicked(&onNewSession, self);
        priv.new_session_btn = new_session_btn;

        // Create list view
        const factory = gtk.SignalListItemFactory.new();
        factory.connectSetup(&setupSessionItem, null);
        factory.connectBind(&bindSessionItem, null);

        const selection = gtk.SingleSelection.new(store.as(gio.ListModel));
        const list_view = gtk.ListView.new(selection.as(gtk.SelectionModel), factory);
        list_view.setSingleClickActivate(true);
        _ = list_view.connectActivate(&onSessionActivated, self);
        priv.sessions_list = list_view;

        // Create scrolled window
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setChild(list_view.as(gtk.Widget));
        scrolled.setVexpand(true);

        // Create header bar
        const header = adw.HeaderBar.new();
        header.setTitleWidget(gtk.Label.new("Session Manager"));
        header.packStart(search_entry.as(gtk.Widget));
        header.packEnd(new_session_btn.as(gtk.Widget));

        // Create main page
        const page = adw.PreferencesPage.new();
        page.setIconName("view-grid-symbolic");
        page.setTitle("Sessions");

        const group = adw.PreferencesGroup.new();
        group.setTitle("Terminal Sessions");
        group.setDescription("Manage multiple terminal sessions and tabs");
        group.add(scrolled.as(gtk.Widget));

        page.add(group.as(gtk.Widget));
        self.as(adw.PreferencesWindow).add(page.as(gtk.Widget));

        // Load sessions
        loadSessions(self);
    }

    fn setupSessionItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.horizontal, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(6);
        box.setMarginBottom(6);

        const status_indicator = gtk.Box.new(gtk.Orientation.vertical, 0);
        status_indicator.setMinContentWidth(4);
        status_indicator.addCssClass("status-indicator");

        const icon = gtk.Image.new();
        icon.setIconName("terminal-symbolic");
        icon.setIconSize(gtk.IconSize.large);

        const info_box = gtk.Box.new(gtk.Orientation.vertical, 4);
        info_box.setHexpand(true);
        info_box.setHalign(gtk.Align.start);

        const title_label = gtk.Label.new("");
        title_label.setXalign(0);
        title_label.addCssClass("title-4");

        const cwd_label = gtk.Label.new("");
        cwd_label.setXalign(0);
        cwd_label.addCssClass("dim-label");
        cwd_label.setEllipsize(gtk.EllipsizeMode.start);

        const meta_label = gtk.Label.new("");
        meta_label.setXalign(0);
        meta_label.addCssClass("caption");
        meta_label.addCssClass("dim-label");

        info_box.append(title_label.as(gtk.Widget));
        info_box.append(cwd_label.as(gtk.Widget));
        info_box.append(meta_label.as(gtk.Widget));

        const action_box = gtk.Box.new(gtk.Orientation.horizontal, 4);
        const focus_btn = gtk.Button.new();
        focus_btn.setIconName("go-jump-symbolic");
        focus_btn.setTooltipText("Focus");
        focus_btn.addCssClass("circular");
        focus_btn.addCssClass("flat");

        const close_btn = gtk.Button.new();
        close_btn.setIconName("window-close-symbolic");
        close_btn.setTooltipText("Close");
        close_btn.addCssClass("circular");
        close_btn.addCssClass("flat");
        close_btn.addCssClass("destructive-action");

        action_box.append(focus_btn.as(gtk.Widget));
        action_box.append(close_btn.as(gtk.Widget));

        box.append(status_indicator.as(gtk.Widget));
        box.append(icon.as(gtk.Widget));
        box.append(info_box.as(gtk.Widget));
        box.append(action_box.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));

        // Connect signal handlers once during setup
        _ = focus_btn.connectClicked(&onFocusSessionListItem, item);
        _ = close_btn.connectClicked(&onCloseSessionListItem, item);
    }

    fn bindSessionItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const session_item = @as(*SessionItem, @ptrCast(@alignCast(entry)));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |indicator| {
            // Set indicator color based on active status
            indicator.as(gtk.Box).addCssClass(if (session_item.is_active) "active-indicator" else "inactive-indicator");
            indicator.as(gtk.Box).removeCssClass(if (session_item.is_active) "inactive-indicator" else "active-indicator");

            if (indicator.getNextSibling()) |icon| {
                if (icon.getNextSibling()) |info_box| {
                    if (info_box.as(gtk.Box).getFirstChild()) |title| {
                        title.as(gtk.Label).setText(session_item.title);
                        if (title.getNextSibling()) |cwd| {
                            cwd.as(gtk.Label).setText(session_item.cwd);
                            if (cwd.getNextSibling()) |meta| {
                                // Use separate buffer for timestamp to avoid use-after-return
                                var time_buf: [64]u8 = undefined;
                                const time_str = formatTimestamp(&time_buf, session_item.last_used);
                                var meta_buf: [256]u8 = undefined;
                                const meta_text = std.fmt.bufPrintZ(&meta_buf, "{s} • {s}", .{ session_item.shell, time_str }) catch "Session";
                                meta.as(gtk.Label).setText(meta_text);
                            }
                        }
                    }
                }
            }
        }
    }

    /// Format timestamp into caller-provided buffer to avoid use-after-return
    fn formatTimestamp(buf: []u8, timestamp: i64) [:0]const u8 {
        const now = std.time.timestamp();
        const diff = now - timestamp;
        if (diff < 60) {
            return std.fmt.bufPrintZ(buf, "Just now", .{}) catch "Recently";
        } else if (diff < 3600) {
            const minutes = @divFloor(diff, 60);
            return std.fmt.bufPrintZ(buf, "{d} minutes ago", .{minutes}) catch "Recently";
        } else if (diff < 86400) {
            const hours = @divFloor(diff, 3600);
            return std.fmt.bufPrintZ(buf, "{d} hours ago", .{hours}) catch "Today";
        } else {
            const days = @divFloor(diff, 86400);
            return std.fmt.bufPrintZ(buf, "{d} days ago", .{days}) catch "Earlier";
        }
    }

    fn onSearchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        _ = entry;
        _ = self;
        // TODO: Implement search filtering
    }

    fn onNewSession(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Create new session
        log.info("New session clicked", .{});
    }

    fn onSessionActivated(_: *gtk.ListView, position: u32, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.sessions_store) |store| {
            if (store.getItem(position)) |item| {
                const session_item: *SessionItem = @ptrCast(@alignCast(item));
                session_item.last_used = std.time.timestamp();
                // TODO: Focus session
                log.info("Session activated: {s}", .{session_item.id});
            }
        }
    }

    fn onFocusSessionListItem(_: *gtk.Button, list_item: *gtk.ListItem) callconv(.c) void {
        const entry = list_item.getItem() orelse return;
        const session_item = @as(*SessionItem, @ptrCast(@alignCast(entry)));
        session_item.last_used = std.time.timestamp();
        // TODO: Focus session
        log.info("Focus session: {s}", .{session_item.id});
    }

    fn onCloseSessionListItem(_: *gtk.Button, list_item: *gtk.ListItem) callconv(.c) void {
        const entry = list_item.getItem() orelse return;
        const session_item = @as(*SessionItem, @ptrCast(@alignCast(entry)));
        // TODO: Close session
        log.info("Close session: {s}", .{session_item.id});
    }

    fn loadSessions(self: *Self) void {
        const priv = getPriv(self);
        const store = priv.sessions_store orelse return;

        // Stub data for predictable UI behavior until real session integration
        const stub_sessions = [_]struct { id: []const u8, title: []const u8, cwd: []const u8, shell: []const u8, active: bool }{
            .{ .id = "session-1", .title = "Main Terminal", .cwd = "/home/user/projects", .shell = "/bin/zsh", .active = true },
            .{ .id = "session-2", .title = "Server Logs", .cwd = "/var/log", .shell = "/bin/bash", .active = false },
            .{ .id = "session-3", .title = "Development", .cwd = "/home/user/dev", .shell = "/bin/zsh", .active = false },
        };

        for (stub_sessions) |session| {
            const item = SessionItem.new(session.id, session.title, session.cwd, session.shell) catch |err| {
                log.err("Failed to allocate SessionItem for '{s}': {}", .{ session.id, err });
                continue;
            };
            item.is_active = session.active;
            store.append(item.as(gobject.Object));
        }

        log.info("Loaded {d} stub sessions", .{stub_sessions.len});
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.PreferencesWindow).setTransientFor(parent.as(gtk.Window));
        self.as(adw.PreferencesWindow).present();
    }
};
