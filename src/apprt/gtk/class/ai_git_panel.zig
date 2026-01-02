//! Git Integration Panel UI
//! Provides Warp-like enhanced git operations panel

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

const log = std.log.scoped(.gtk_ghostty_git_panel);

pub const GitPanelDialog = extern struct {
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
        status_list: ?*gtk.ListView = null,
        status_store: ?*gio.ListStore = null,
        branch_label: ?*gtk.Label = null,
        status_label: ?*gtk.Label = null,
        refresh_btn: ?*gtk.Button = null,
        commit_btn: ?*gtk.Button = null,
        push_btn: ?*gtk.Button = null,
        pull_btn: ?*gtk.Button = null,
        pub var offset: c_int = 0;
    };

    pub const GitStatusItem = extern struct {
        parent_instance: gobject.Object,
        file: [:0]const u8,
        status: GitFileStatus,
        staged: bool = false,

        pub const Parent = gobject.Object;

        pub const GitFileStatus = enum {
            modified,
            added,
            deleted,
            renamed,
            untracked,
            conflicted,
        };

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &GitStatusItem.dispose);
            }

            fn dispose(self: *GitStatusItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                alloc.free(self.file);
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }
        };

        pub const getGObjectType = gobject.ext.defineClass(GitStatusItem, .{
            .name = "GhosttyGitStatusItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub fn new(alloc: Allocator, file: []const u8, status: GitFileStatus) !*GitStatusItem {
            const self = gobject.ext.newInstance(GitStatusItem, .{});
            self.file = try alloc.dupeZ(u8, file);
            errdefer alloc.free(self.file);
            self.status = status;
            return self;
        }

        pub fn deinit(self: *GitStatusItem, alloc: Allocator) void {
            alloc.free(self.file);
        }
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        fn dispose(self: *Self) callconv(.c) void {
            const priv = getPriv(self);
            if (priv.status_store) |store| {
                store.removeAll();
            }
            gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
        }

        pub const as = C.Class.as;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyGitPanelDialog",
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

        // Create status store
        const store = gio.ListStore.new(GitStatusItem.getGObjectType());
        priv.status_store = store;

        // Create header bar
        const header = adw.HeaderBar.new();
        header.setTitleWidget(gtk.Label.new("Git Panel"));

        // Create toolbar
        const toolbar = gtk.Box.new(gtk.Orientation.horizontal, 12);
        toolbar.setMarginStart(12);
        toolbar.setMarginEnd(12);
        toolbar.setMarginTop(12);
        toolbar.setMarginBottom(12);

        const branch_label = gtk.Label.new("Branch: main");
        branch_label.setHalign(gtk.Align.start);
        branch_label.addCssClass("title-4");
        priv.branch_label = branch_label;

        const status_label = gtk.Label.new("Clean working tree");
        status_label.setHalign(gtk.Align.start);
        status_label.addCssClass("dim-label");
        priv.status_label = status_label;

        const refresh_btn = gtk.Button.new();
        refresh_btn.setIconName("view-refresh-symbolic");
        refresh_btn.setTooltipText("Refresh");
        refresh_btn.addCssClass("flat");
        _ = refresh_btn.connectClicked(&onRefresh, self);
        priv.refresh_btn = refresh_btn;

        const commit_btn = gtk.Button.new();
        commit_btn.setIconName("vcs-commit-symbolic");
        commit_btn.setLabel("Commit");
        commit_btn.setTooltipText("Commit Changes");
        commit_btn.addCssClass("suggested-action");
        _ = commit_btn.connectClicked(&onCommit, self);
        priv.commit_btn = commit_btn;

        const push_btn = gtk.Button.new();
        push_btn.setIconName("vcs-push-symbolic");
        push_btn.setLabel("Push");
        push_btn.setTooltipText("Push to Remote");
        _ = push_btn.connectClicked(&onPush, self);
        priv.push_btn = push_btn;

        const pull_btn = gtk.Button.new();
        pull_btn.setIconName("vcs-pull-symbolic");
        pull_btn.setLabel("Pull");
        pull_btn.setTooltipText("Pull from Remote");
        _ = pull_btn.connectClicked(&onPull, self);
        priv.pull_btn = pull_btn;

        toolbar.append(branch_label.as(gtk.Widget));
        toolbar.append(status_label.as(gtk.Widget));
        toolbar.append(refresh_btn.as(gtk.Widget));
        toolbar.append(commit_btn.as(gtk.Widget));
        toolbar.append(push_btn.as(gtk.Widget));
        toolbar.append(pull_btn.as(gtk.Widget));

        // Create list view
        const factory = gtk.SignalListItemFactory.new();
        factory.connectSetup(&setupStatusItem, null);
        factory.connectBind(&bindStatusItem, null);

        const selection = gtk.SingleSelection.new(store.as(gio.ListModel));
        const list_view = gtk.ListView.new(selection.as(gtk.SelectionModel), factory);
        list_view.setSingleClickActivate(true);
        _ = list_view.connectActivate(&onStatusActivated, self);
        priv.status_list = list_view;

        // Create scrolled window
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setChild(list_view.as(gtk.Widget));
        scrolled.setVexpand(true);
        scrolled.setMarginStart(12);
        scrolled.setMarginEnd(12);
        scrolled.setMarginBottom(12);

        // Create main box
        const main_box = gtk.Box.new(gtk.Orientation.vertical, 12);
        main_box.append(toolbar.as(gtk.Widget));
        main_box.append(scrolled.as(gtk.Widget));

        // Create page
        const page = adw.NavigationPage.new();
        page.setTitle("Git");
        page.setChild(main_box.as(gtk.Widget));

        self.as(adw.NavigationView).add(page.as(adw.NavigationPage));

        // Load git status
        loadGitStatus(self);
    }

    fn setupStatusItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.horizontal, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(4);
        box.setMarginBottom(4);

        const checkbox = gtk.CheckButton.new();
        checkbox.setValign(gtk.Align.center);

        const icon = gtk.Image.new();
        icon.setIconSize(gtk.IconSize.normal);

        const file_label = gtk.Label.new("");
        file_label.setXalign(0);
        file_label.setHexpand(true);
        file_label.setSelectable(true);

        box.append(checkbox.as(gtk.Widget));
        box.append(icon.as(gtk.Widget));
        box.append(file_label.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));

        // Connect signal handlers once during setup
        _ = checkbox.connectToggled(&onStageToggleListItem, item);
    }

    fn bindStatusItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const status_item = @as(*GitStatusItem, @ptrCast(@alignCast(entry)));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |checkbox| {
            checkbox.as(gtk.CheckButton).setActive(status_item.staged);
            if (checkbox.getNextSibling()) |icon| {
                const icon_name = switch (status_item.status) {
                    .modified => "document-modified-symbolic",
                    .added => "list-add-symbolic",
                    .deleted => "user-trash-symbolic",
                    .renamed => "edit-rename-symbolic",
                    .untracked => "document-new-symbolic",
                    .conflicted => "dialog-error-symbolic",
                };
                icon.as(gtk.Image).setFromIconName(icon_name);
                if (icon.getNextSibling()) |file| {
                    file.as(gtk.Label).setText(status_item.file);
                }
            }
        }
    }

    fn onStageToggleListItem(checkbox: *gtk.CheckButton, list_item: *gtk.ListItem) callconv(.c) void {
        const entry = list_item.getItem() orelse return;
        const status_item = @as(*GitStatusItem, @ptrCast(@alignCast(entry)));
        status_item.staged = checkbox.getActive();
        // TODO: Stage/unstage file
        log.info("Toggle stage: {s} = {}", .{ status_item.file, status_item.staged });
    }

    fn onRefresh(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Refresh git status
        log.info("Refresh git status", .{});
    }

    fn onCommit(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Show commit dialog
        log.info("Commit clicked", .{});
    }

    fn onPush(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Push to remote
        log.info("Push clicked", .{});
    }

    fn onPull(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Pull from remote
        log.info("Pull clicked", .{});
    }

    fn onStatusActivated(_: *gtk.ListView, position: u32, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.status_store) |store| {
            if (store.getItem(position)) |item| {
                const status_item: *GitStatusItem = @ptrCast(@alignCast(item));
                // TODO: Show file diff
                log.info("Status activated: {s}", .{status_item.file});
            }
        }
    }

    fn loadGitStatus(_: *Self) void {
        // TODO: Load git status from repository
        log.info("Loading git status...", .{});
    }

    pub fn show(self: *Self, parent: *Window) void {
        // Git panel is typically shown as a sidebar
        // For now, we'll present it as a window
        if (parent.as(gtk.Window).getTransientFor()) |transient_parent| {
            self.as(adw.NavigationView).as(gtk.Widget).setParent(transient_parent.as(gtk.Window));
        }
        // TODO: Implement proper presentation
    }
};
