//! Quick Actions Panel UI
//! Provides Warp-like quick actions panel for common terminal tasks

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

const log = std.log.scoped(.gtk_ghostty_quick_actions);

pub const QuickActionsPanel = extern struct {
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
        actions_grid: ?*gtk.GridView = null,
        actions_store: ?*gio.ListStore = null,
        pub var offset: c_int = 0;
    };

    pub const ActionItem = extern struct {
        parent_instance: gobject.Object,
        id: [:0]const u8,
        label: [:0]const u8,
        description: ?[:0]const u8 = null,
        icon_name: [:0]const u8,
        command: ?[:0]const u8 = null,
        action: ?[:0]const u8 = null,

        pub const Parent = gobject.Object;

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &ActionItem.dispose);
            }

            fn dispose(self: *ActionItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                alloc.free(self.id);
                alloc.free(self.label);
                if (self.description) |desc| alloc.free(desc);
                alloc.free(self.icon_name);
                if (self.command) |cmd| alloc.free(cmd);
                if (self.action) |act| alloc.free(act);
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }
        };

        pub const getGObjectType = gobject.ext.defineClass(ActionItem, .{
            .name = "GhosttyActionItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub fn new(alloc: Allocator, id: []const u8, label: []const u8, icon_name: []const u8, command: ?[]const u8, action: ?[]const u8) !*ActionItem {
            const self = gobject.ext.newInstance(ActionItem, .{});
            self.id = try alloc.dupeZ(u8, id);
            errdefer alloc.free(self.id);
            self.label = try alloc.dupeZ(u8, label);
            errdefer alloc.free(self.label);
            self.icon_name = try alloc.dupeZ(u8, icon_name);
            errdefer alloc.free(self.icon_name);
            if (command) |cmd| {
                self.command = try alloc.dupeZ(u8, cmd);
                errdefer alloc.free(self.command.?);
            }
            if (action) |act| {
                self.action = try alloc.dupeZ(u8, act);
                errdefer alloc.free(self.action.?);
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

            // Clean up all action items - just removeAll, GObject dispose handles item cleanup
            if (priv.actions_store) |store| {
                store.removeAll();
            }

            gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
        }

        pub const as = C.Class.as;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyQuickActionsPanel",
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

        // Create actions store
        const store = gio.ListStore.new(ActionItem.getGObjectType());
        priv.actions_store = store;

        // Create factory for grid items
        const factory = gtk.SignalListItemFactory.new();
        factory.connectSetup(&setupActionItem, null);
        factory.connectBind(&bindActionItem, null);

        // Create grid view
        const selection = gtk.SingleSelection.new(store.as(gio.ListModel));
        const grid_view = gtk.GridView.new(selection.as(gtk.SelectionModel), factory);
        grid_view.setMaxColumns(3);
        grid_view.setColumnSpacing(12);
        grid_view.setRowSpacing(12);
        grid_view.setSingleClickActivate(true);
        _ = grid_view.connectActivate(&onActionActivated, self);
        priv.actions_grid = grid_view;

        // Create scrolled window
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setChild(grid_view.as(gtk.Widget));
        scrolled.setVexpand(true);
        scrolled.setMarginStart(12);
        scrolled.setMarginEnd(12);
        scrolled.setMarginTop(12);
        scrolled.setMarginBottom(12);

        // Create header bar
        const header = adw.HeaderBar.new();
        header.setTitleWidget(gtk.Label.new("Quick Actions"));

        // Create page
        const page = adw.NavigationPage.new();
        page.setTitle("Quick Actions");
        page.setChild(scrolled.as(gtk.Widget));

        self.as(adw.NavigationView).add(page.as(adw.NavigationPage));

        // Load actions
        loadActions(self);
    }

    fn setupActionItem(_: *gtk.SignalListItemFactory, list_item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const button = gtk.Button.new();
        button.addCssClass("quick-action-button");
        button.setVexpand(false);
        button.setHexpand(false);

        const box = gtk.Box.new(gtk.Orientation.vertical, 8);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        const icon = gtk.Image.new();
        icon.setIconSize(gtk.IconSize.large);

        const label = gtk.Label.new("");
        label.addCssClass("title-5");
        label.setWrap(true);
        label.setMaxWidthChars(20);

        box.append(icon.as(gtk.Widget));
        box.append(label.as(gtk.Widget));

        button.setChild(box.as(gtk.Widget));
        list_item.setChild(button.as(gtk.Widget));

        // Connect signal handler once during setup to prevent leaks on rebind
        _ = button.connectClicked(&onActionClickedListItem, list_item);
    }

    fn bindActionItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const action_item = @as(*ActionItem, @ptrCast(@alignCast(entry)));
        const button = item.getChild() orelse return;
        const btn_widget = button.as(gtk.Button);

        btn_widget.setTooltipText(if (action_item.description) |desc| desc else action_item.label);

        if (btn_widget.getChild()) |box| {
            if (box.as(gtk.Box).getFirstChild()) |icon| {
                icon.as(gtk.Image).setFromIconName(action_item.icon_name);
                if (icon.getNextSibling()) |label| {
                    label.as(gtk.Label).setText(action_item.label);
                }
            }
        }
    }

    fn onActionClickedListItem(button: *gtk.Button, list_item: *gtk.ListItem) callconv(.c) void {
        const entry = list_item.getItem() orelse return;
        const action_item = @as(*ActionItem, @ptrCast(@alignCast(entry)));
        onActionClicked(button, action_item);
    }

    fn onActionActivated(_: *gtk.GridView, position: u32, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.actions_store) |store| {
            if (store.getItem(position)) |item| {
                const action_item: *ActionItem = @ptrCast(@alignCast(item));
                executeAction(action_item);
            }
        }
    }

    fn onActionClicked(_: *gtk.Button, action_item: *ActionItem) callconv(.c) void {
        executeAction(action_item);
    }

    fn executeAction(action_item: *ActionItem) void {
        if (action_item.command) |cmd| {
            // TODO: Execute command in terminal
            log.info("Execute command: {s}", .{cmd});
        } else if (action_item.action) |act| {
            // TODO: Trigger action
            log.info("Trigger action: {s}", .{act});
        }
    }

    fn loadActions(self: *Self) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Add common quick actions
        const actions = [_]struct { id: []const u8, label: []const u8, icon: []const u8, command: []const u8 }{
            .{ .id = "clear", .label = "Clear Terminal", .icon = "edit-clear-symbolic", .command = "clear" },
            .{ .id = "git-status", .label = "Git Status", .icon = "git-symbolic", .command = "git status" },
            .{ .id = "git-pull", .label = "Git Pull", .icon = "git-symbolic", .command = "git pull" },
            .{ .id = "docker-ps", .label = "Docker PS", .icon = "docker-symbolic", .command = "docker ps" },
            .{ .id = "list-files", .label = "List Files", .icon = "folder-symbolic", .command = "ls -la" },
            .{ .id = "processes", .label = "Processes", .icon = "system-run-symbolic", .command = "ps aux" },
        };

        const store = priv.actions_store orelse return;
        for (actions) |action| {
            const action_item = ActionItem.new(alloc, action.id, action.label, action.icon, action.command, null) catch |err| {
                log.err("Failed to allocate ActionItem for quick action '{s}': {}", .{ action.id, err });
                continue;
            };
            store.append(action_item.as(gobject.Object));
        }

        log.info("Loaded {d} quick actions", .{actions.len});
    }

    pub fn show(self: *Self, parent: *Window) void {
        // Quick actions panel is typically shown as a sidebar or overlay
        // For now, we'll present it as a window
        if (parent.as(gtk.Window).getTransientFor()) |transient_parent| {
            self.as(adw.NavigationView).as(gtk.Widget).setParent(transient_parent.as(gtk.Window));
        }
        // TODO: Implement proper presentation
    }
};
