//! Session Sharing UI
//! Provides Warp-like session sharing and collaboration features

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

const log = std.log.scoped(.gtk_ghostty_session_sharing);

const CollaborationManager = @import("../../../ai/collaboration.zig").CollaborationManager;

pub const SessionSharingDialog = extern struct {
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
        collaboration_manager: ?CollaborationManager = null,
        members_list: ?*gtk.ListView = null,
        members_store: ?*gio.ListStore = null,
        share_btn: ?*gtk.Button = null,
        session_id_label: ?*gtk.Label = null,

        pub var offset: c_int = 0;
    };

    pub const MemberItem = extern struct {
        parent_instance: gobject.Object,
        name: []const u8,
        email: []const u8,
        role: []const u8,
        cursor_position: ?[]const u8 = null,

        pub const Parent = gobject.Object;
        pub const getGObjectType = gobject.ext.defineClass(MemberItem, .{
            .name = "GhosttyMemberItem",
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

        pub fn new(alloc: Allocator, name: []const u8, email: []const u8, role: []const u8) !*MemberItem {
            const self = gobject.ext.newInstance(MemberItem, .{});
            self.name = try alloc.dupe(u8, name);
            errdefer alloc.free(self.name);
            self.email = try alloc.dupe(u8, email);
            errdefer alloc.free(self.email);
            self.role = try alloc.dupe(u8, role);
            errdefer alloc.free(self.role);
            return self;
        }

        pub fn deinit(self: *MemberItem, alloc: Allocator) void {
            alloc.free(self.name);
            alloc.free(self.email);
            alloc.free(self.role);
            if (self.cursor_position) |pos| alloc.free(pos);
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
        .name = "GhosttySessionSharingDialog",
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

        self.as(adw.PreferencesWindow).setTitle("Session Sharing");
        self.as(adw.PreferencesWindow).setDefaultSize(600, 500);

        const page = adw.PreferencesPage.new();
        page.setTitle("Collaboration");
        page.setIconName("system-users-symbolic");

        // Session info group
        const session_group = adw.PreferencesGroup.new();
        session_group.setTitle("Current Session");
        session_group.setDescription("Share your terminal session with team members");

        const session_id_label = gtk.Label.new("Not shared");
        session_id_label.setSelectable(@intFromBool(true));
        priv.session_id_label = session_id_label;
        session_group.add(session_id_label.as(gtk.Widget));

        const share_btn = gtk.Button.new();
        share_btn.setLabel("Start Sharing");
        share_btn.setIconName("emblem-shared-symbolic");
        priv.share_btn = share_btn;
        _ = share_btn.connectClicked(&toggleSharing, self);
        session_group.add(share_btn.as(gtk.Widget));

        page.add(session_group.as(gtk.Widget));

        // Members group
        const members_group = adw.PreferencesGroup.new();
        members_group.setTitle("Active Members");
        members_group.setDescription("People currently viewing this session");

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
        scrolled.setMinContentHeight(200);

        const members_store = gio.ListStore.new(MemberItem.getGObjectType());
        priv.members_store = members_store;

        const selection = gtk.NoSelection.new(members_store.as(gio.ListModel));
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupMemberItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindMemberItem, null, .{});

        const members_list = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        priv.members_list = members_list;
        scrolled.setChild(members_list.as(gtk.Widget));
        members_group.add(scrolled.as(gtk.Widget));

        page.add(members_group.as(gtk.Widget));
        self.as(adw.PreferencesWindow).add(page.as(adw.PreferencesPage));
    }

    fn setupMemberItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.horizontal, 12);
        box.setMarginStart(8);
        box.setMarginEnd(8);
        box.setMarginTop(4);
        box.setMarginBottom(4);

        const info_box = gtk.Box.new(gtk.Orientation.vertical, 2);
        info_box.setHexpand(@intFromBool(true));

        const name_label = gtk.Label.new("");
        name_label.setXalign(0);
        name_label.getStyleContext().addClass("heading");
        info_box.append(name_label.as(gtk.Widget));

        const email_label = gtk.Label.new("");
        email_label.setXalign(0);
        email_label.getStyleContext().addClass("dim-label");
        info_box.append(email_label.as(gtk.Widget));

        const role_label = gtk.Label.new("");
        role_label.setXalign(0);
        role_label.getStyleContext().addClass("dim-label");
        info_box.append(role_label.as(gtk.Widget));

        box.append(info_box.as(gtk.Widget));
        item.setChild(box.as(gtk.Widget));
    }

    fn bindMemberItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const member_item = @as(*MemberItem, @ptrCast(entry));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |info_box| {
            if (info_box.as(gtk.Box).getFirstChild()) |name| {
                name.as(gtk.Label).setText(member_item.name);
                if (name.getNextSibling()) |email| {
                    email.as(gtk.Label).setText(member_item.email);
                    if (email.getNextSibling()) |role| {
                        role.as(gtk.Label).setText(member_item.role);
                    }
                }
            }
        }
    }

    fn toggleSharing(button: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Initialize collaboration manager if needed
        if (priv.collaboration_manager == null) {
            priv.collaboration_manager = CollaborationManager.init(alloc) catch {
                log.err("Failed to initialize collaboration manager", .{});
                return;
            };
        }

        // TODO: Implement actual sharing toggle
        log.info("Toggling session sharing...", .{});
        if (button.getLabel()) |label| {
            if (std.mem.eql(u8, label, "Start Sharing")) {
                button.setLabel("Stop Sharing");
                if (priv.session_id_label) |label_widget| {
                    label_widget.setText("Session ID: abc123");
                }
            } else {
                button.setLabel("Start Sharing");
                if (priv.session_id_label) |label_widget| {
                    label_widget.setText("Not shared");
                }
            }
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Clean up all member items
        if (priv.members_store) |store| {
            const n = store.getNItems();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (store.getItem(i)) |item| {
                    const member_item: *MemberItem = @ptrCast(@alignCast(item));
                    member_item.deinit(alloc);
                }
            }
        }

        // Clean up collaboration manager
        if (priv.collaboration_manager) |*manager| {
            manager.deinit();
        }

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.PreferencesWindow).setTransientFor(parent.as(gtk.Window));
        self.as(adw.PreferencesWindow).present();
    }
};
