//! Theme Customization UI
//! Provides Warp-like theme customization with AI-generated theme suggestions

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

const log = std.log.scoped(.gtk_ghostty_theme_customization);

const ThemeSuggestions = @import("../../../ai/theme_suggestions.zig").ThemeSuggestions;

pub const ThemeCustomizationDialog = extern struct {
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
        theme_suggestions: ?ThemeSuggestions = null,
        themes_list: ?*gtk.ListView = null,
        themes_store: ?*gio.ListStore = null,
        preview_area: ?*gtk.Box = null,
        generate_btn: ?*gtk.Button = null,

        pub var offset: c_int = 0;
    };

    pub const ThemeItem = extern struct {
        parent_instance: gobject.Object,
        name: [:0]const u8,
        description: [:0]const u8,
        colors: [:0]const u8, // JSON string of color scheme
        preview_image: ?[:0]const u8 = null,

        pub const Parent = gobject.Object;
        pub const getGObjectType = gobject.ext.defineClass(ThemeItem, .{
            .name = "GhosttyThemeItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &ThemeItem.dispose);
                gobject.Object.virtual_methods.finalize.implement(class, &ThemeItem.finalize);
            }

            fn dispose(self: *ThemeItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                if (self.name.len > 0) {
                    alloc.free(self.name);
                    self.name = "";
                }
                if (self.description.len > 0) {
                    alloc.free(self.description);
                    self.description = "";
                }
                if (self.colors.len > 0) {
                    alloc.free(self.colors);
                    self.colors = "";
                }
                if (self.preview_image) |img| {
                    alloc.free(img);
                    self.preview_image = null;
                }
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }

            fn finalize(self: *ThemeItem) callconv(.c) void {
                gobject.Object.virtual_methods.finalize.call(ItemClass.parent, self);
            }
        };

        pub fn new(alloc: Allocator, name: []const u8, description: []const u8, colors: []const u8) !*ThemeItem {
            const self = gobject.ext.newInstance(ThemeItem, .{});
            self.name = try alloc.dupeZ(u8, name);
            errdefer alloc.free(self.name);
            self.description = try alloc.dupeZ(u8, description);
            errdefer alloc.free(self.description);
            self.colors = try alloc.dupeZ(u8, colors);
            errdefer alloc.free(self.colors);
            return self;
        }

        pub fn deinit(self: *ThemeItem, alloc: Allocator) void {
            alloc.free(self.name);
            alloc.free(self.description);
            alloc.free(self.colors);
            if (self.preview_image) |img| alloc.free(img);
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
        .name = "GhosttyThemeCustomizationDialog",
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

        self.as(adw.PreferencesWindow).setTitle("Theme Customization");
        self.as(adw.PreferencesWindow).setDefaultSize(800, 600);

        const page = adw.PreferencesPage.new();
        page.setTitle("AI Theme Suggestions");
        page.setIconName("preferences-color-symbolic");

        const group = adw.PreferencesGroup.new();
        group.setTitle("Generated Themes");
        group.setDescription("AI-generated theme suggestions based on your preferences");

        // Generate button
        const generate_btn = gtk.Button.new();
        generate_btn.setLabel("Generate New Themes");
        generate_btn.setIconName("view-refresh-symbolic");
        priv.generate_btn = generate_btn;
        _ = generate_btn.connectClicked(&generateThemes, self);
        group.add(generate_btn.as(gtk.Widget));

        // Themes list
        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
        scrolled.setMinContentHeight(400);

        const themes_store = gio.ListStore.new(ThemeItem.getGObjectType());
        priv.themes_store = themes_store;

        const selection = gtk.SingleSelection.new(themes_store.as(gio.ListModel));
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupThemeItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindThemeItem, null, .{});

        const themes_list = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        priv.themes_list = themes_list;
        scrolled.setChild(themes_list.as(gtk.Widget));
        group.add(scrolled.as(gtk.Widget));

        page.add(group.as(gtk.Widget));
        self.as(adw.PreferencesWindow).add(page.as(adw.PreferencesPage));
    }

    fn setupThemeItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.horizontal, 12);
        box.setMarginStart(8);
        box.setMarginEnd(8);
        box.setMarginTop(4);
        box.setMarginBottom(4);

        const info_box = gtk.Box.new(gtk.Orientation.vertical, 4);
        info_box.setHexpand(@intFromBool(true));

        const name_label = gtk.Label.new("");
        name_label.setXalign(0);
        name_label.getStyleContext().addClass("heading");
        info_box.append(name_label.as(gtk.Widget));

        const desc_label = gtk.Label.new("");
        desc_label.setXalign(0);
        desc_label.setWrap(@intFromBool(true));
        info_box.append(desc_label.as(gtk.Widget));

        box.append(info_box.as(gtk.Widget));

        const apply_btn = gtk.Button.new();
        apply_btn.setLabel("Apply");
        apply_btn.setIconName("document-open-symbolic");
        box.append(apply_btn.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));
    }

    fn bindThemeItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const theme_item = @as(*ThemeItem, @ptrCast(entry));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |info_box| {
            if (info_box.as(gtk.Box).getFirstChild()) |name| {
                name.as(gtk.Label).setText(theme_item.name);
                if (name.getNextSibling()) |desc| {
                    desc.as(gtk.Label).setText(theme_item.description);
                }
            }
        }
    }

    fn generateThemes(button: *gtk.Button, self: *Self) callconv(.c) void {
        _ = button;
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Initialize theme suggestions if needed
        if (priv.theme_suggestions == null) {
            priv.theme_suggestions = ThemeSuggestions.init(alloc) catch {
                log.err("Failed to initialize theme suggestions", .{});
                return;
            };
        }

        // Generate themes (async)
        // TODO: Implement async theme generation
        log.info("Generating theme suggestions...", .{});
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);

        // Clean up all theme items - just removeAll, GObject dispose handles item cleanup
        if (priv.themes_store) |store| {
            store.removeAll();
        }

        // Clean up theme suggestions
        if (priv.theme_suggestions) |*suggestions| {
            suggestions.deinit();
        }

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.PreferencesWindow).setTransientFor(parent.as(gtk.Window));
        self.as(adw.PreferencesWindow).present();
    }
};
