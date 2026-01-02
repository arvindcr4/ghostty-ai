//! Themes Gallery UI
//! Provides Warp-like gallery for browsing and applying terminal themes

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

const log = std.log.scoped(.gtk_ghostty_themes_gallery);

pub const ThemesGalleryDialog = extern struct {
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
        themes_grid: ?*gtk.GridView = null,
        themes_store: ?*gio.ListStore = null,
        category_filter: ?*gtk.DropDown = null,
        search_entry: ?*gtk.SearchEntry = null,
        pub var offset: c_int = 0;
    };

    pub const ThemeGalleryItem = extern struct {
        parent_instance: gobject.Object,
        name: [:0]const u8,
        description: [:0]const u8,
        category: [:0]const u8,
        preview_colors: [:0]const u8, // JSON array of colors
        author: ?[:0]const u8 = null,
        is_installed: bool = false,

        pub const Parent = gobject.Object;

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &ThemeGalleryItem.dispose);
            }

            fn dispose(self: *ThemeGalleryItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                alloc.free(self.name);
                alloc.free(self.description);
                alloc.free(self.category);
                alloc.free(self.preview_colors);
                if (self.author) |auth| alloc.free(auth);
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }
        };

        pub const getGObjectType = gobject.ext.defineClass(ThemeGalleryItem, .{
            .name = "GhosttyThemeGalleryItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub fn new(alloc: Allocator, name: []const u8, description: []const u8, category: []const u8, preview_colors: []const u8) !*ThemeGalleryItem {
            const self = gobject.ext.newInstance(ThemeGalleryItem, .{});
            self.name = try alloc.dupeZ(u8, name);
            errdefer alloc.free(self.name);
            self.description = try alloc.dupeZ(u8, description);
            errdefer alloc.free(self.description);
            self.category = try alloc.dupeZ(u8, category);
            errdefer alloc.free(self.category);
            self.preview_colors = try alloc.dupeZ(u8, preview_colors);
            errdefer alloc.free(self.preview_colors);
            return self;
        }

        pub fn deinit(self: *ThemeGalleryItem, alloc: Allocator) void {
            alloc.free(self.name);
            alloc.free(self.description);
            alloc.free(self.category);
            alloc.free(self.preview_colors);
            if (self.author) |auth| alloc.free(auth);
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
            if (priv.themes_store) |store| {
                store.removeAll();
            }
            gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
        }

        pub const as = C.Class.as;
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyThemesGalleryDialog",
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
        self.as(adw.PreferencesWindow).setTitle("Themes Gallery");

        // Create themes store
        const store = gio.ListStore.new(ThemeGalleryItem.getGObjectType());
        priv.themes_store = store;

        // Create search entry
        const search_entry = gtk.SearchEntry.new();
        search_entry.setPlaceholderText("Search themes...");
        _ = search_entry.connectSearchChanged(&onSearchChanged, self);
        priv.search_entry = search_entry;

        // Create category filter
        const category_store = gio.ListStore.new(gobject.Object.getGObjectType());
        const category_filter = gtk.DropDown.new(category_store.as(gio.ListModel), null);
        category_filter.setTooltipText("Filter by category");
        _ = category_filter.connectNotify("selected", &onCategoryChanged, self);
        priv.category_filter = category_filter;

        // Create grid view
        const factory = gtk.SignalListItemFactory.new();
        factory.connectSetup(&setupThemeItem, null);
        factory.connectBind(&bindThemeItem, null);

        const selection = gtk.SingleSelection.new(store.as(gio.ListModel));
        const grid_view = gtk.GridView.new(selection.as(gtk.SelectionModel), factory);
        grid_view.setMaxColumns(3);
        grid_view.setColumnSpacing(12);
        grid_view.setRowSpacing(12);
        grid_view.setSingleClickActivate(true);
        _ = grid_view.connectActivate(&onThemeActivated, self);
        priv.themes_grid = grid_view;

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
        header.setTitleWidget(gtk.Label.new("Themes Gallery"));
        header.packStart(search_entry.as(gtk.Widget));
        header.packStart(category_filter.as(gtk.Widget));

        // Create main page
        const page = adw.PreferencesPage.new();
        page.setIconName("preferences-color-symbolic");
        page.setTitle("Themes");

        const group = adw.PreferencesGroup.new();
        group.setTitle("Terminal Themes");
        group.setDescription("Browse and apply terminal color themes");
        group.add(scrolled.as(gtk.Widget));

        page.add(group.as(gtk.Widget));
        self.as(adw.PreferencesWindow).add(page.as(gtk.Widget));

        // Load themes
        loadThemes(self);
    }

    fn setupThemeItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const card = gtk.Box.new(gtk.Orientation.vertical, 8);
        card.setMarginStart(6);
        card.setMarginEnd(6);
        card.setMarginTop(6);
        card.setMarginBottom(6);
        card.addCssClass("theme-card");

        // Preview box with colors
        const preview_box = gtk.Box.new(gtk.Orientation.horizontal, 0);
        preview_box.setMinContentHeight(80);
        preview_box.addCssClass("theme-preview");

        // Info box
        const info_box = gtk.Box.new(gtk.Orientation.vertical, 4);
        info_box.setMarginStart(8);
        info_box.setMarginEnd(8);
        info_box.setMarginTop(8);
        info_box.setMarginBottom(8);

        const name_label = gtk.Label.new("");
        name_label.setXalign(0);
        name_label.addCssClass("title-5");

        const desc_label = gtk.Label.new("");
        desc_label.setXalign(0);
        desc_label.addCssClass("caption");
        desc_label.addCssClass("dim-label");
        desc_label.setWrap(true);
        desc_label.setMaxWidthChars(30);

        const category_label = gtk.Label.new("");
        category_label.setXalign(0);
        category_label.addCssClass("caption");
        category_label.addCssClass("dim-label");

        info_box.append(name_label.as(gtk.Widget));
        info_box.append(desc_label.as(gtk.Widget));
        info_box.append(category_label.as(gtk.Widget));

        // Apply button
        const apply_btn = gtk.Button.new();
        apply_btn.setLabel("Apply");
        apply_btn.addCssClass("suggested-action");
        apply_btn.addCssClass("flat");

        card.append(preview_box.as(gtk.Widget));
        card.append(info_box.as(gtk.Widget));
        card.append(apply_btn.as(gtk.Widget));

        item.setChild(card.as(gtk.Widget));

        // Connect signal handler once during setup
        _ = apply_btn.connectClicked(&onApplyThemeListItem, item);
    }

    fn bindThemeItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const theme_item = @as(*ThemeGalleryItem, @ptrCast(@alignCast(entry)));
        const card = item.getChild() orelse return;
        const card_widget = card.as(gtk.Box);

        if (card_widget.getFirstChild()) |preview| {
            // TODO: Render color preview
            if (preview.getNextSibling()) |info_box| {
                if (info_box.as(gtk.Box).getFirstChild()) |name| {
                    name.as(gtk.Label).setText(theme_item.name);
                    if (name.getNextSibling()) |desc| {
                        desc.as(gtk.Label).setText(theme_item.description);
                        if (desc.getNextSibling()) |category| {
                            category.as(gtk.Label).setText(theme_item.category);
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

    fn onCategoryChanged(_: *gobject.Object, _: glib.ParamSpec, self: *Self) callconv(.c) void {
        _ = self;
        // TODO: Implement category filtering
    }

    fn onThemeActivated(_: *gtk.GridView, position: u32, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.themes_store) |store| {
            if (store.getItem(position)) |item| {
                const theme_item: *ThemeGalleryItem = @ptrCast(@alignCast(item));
                // TODO: Show theme preview/details
                log.info("Theme activated: {s}", .{theme_item.name});
            }
        }
    }

    fn onApplyThemeListItem(_: *gtk.Button, list_item: *gtk.ListItem) callconv(.c) void {
        const entry = list_item.getItem() orelse return;
        const theme_item = @as(*ThemeGalleryItem, @ptrCast(@alignCast(entry)));
        // TODO: Apply theme
        log.info("Apply theme: {s}", .{theme_item.name});
    }

    fn loadThemes(_: *Self) void {
        // TODO: Load themes from gallery/registry
        log.info("Loading themes...", .{});
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.PreferencesWindow).setTransientFor(parent.as(gtk.Window));
        self.as(adw.PreferencesWindow).present();
    }
};
