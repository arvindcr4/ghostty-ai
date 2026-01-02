//! Performance Analytics Dashboard
//! Provides Warp-like performance analysis and visualization

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

const log = std.log.scoped(.gtk_ghostty_performance_analytics);

pub const PerformanceAnalyticsDialog = extern struct {
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
        commands_list: ?*gtk.ListView = null,
        commands_store: ?*gio.ListStore = null,
        stats_label: ?*gtk.Label = null,
        refresh_btn: ?*gtk.Button = null,

        pub var offset: c_int = 0;
    };

    pub const CommandStatsItem = extern struct {
        parent_instance: gobject.Object,
        command: [:0]const u8,
        execution_time_ms: u64,
        memory_usage_kb: u64,
        cpu_percent: f32,
        success_rate: f32,
        run_count: u32,

        pub const Parent = gobject.Object;
        pub const getGObjectType = gobject.ext.defineClass(CommandStatsItem, .{
            .name = "GhosttyCommandStatsItem",
            .classInit = &ItemClass.init,
            .parent_class = &ItemClass.parent,
        });

        pub const ItemClass = extern struct {
            parent_class: gobject.Object.Class,
            var parent: *gobject.Object.Class = undefined;

            fn init(class: *ItemClass) callconv(.c) void {
                gobject.Object.virtual_methods.dispose.implement(class, &CommandStatsItem.dispose);
                gobject.Object.virtual_methods.finalize.implement(class, &CommandStatsItem.finalize);
            }

            fn dispose(self: *CommandStatsItem) callconv(.c) void {
                const alloc = Application.default().allocator();
                if (self.command.len > 0) {
                    alloc.free(self.command);
                    self.command = "";
                }
                gobject.Object.virtual_methods.dispose.call(ItemClass.parent, self);
            }

            fn finalize(self: *CommandStatsItem) callconv(.c) void {
                gobject.Object.virtual_methods.finalize.call(ItemClass.parent, self);
            }
        };

        pub fn new(alloc: Allocator, command: []const u8, execution_time_ms: u64, memory_usage_kb: u64, cpu_percent: f32, success_rate: f32, run_count: u32) !*CommandStatsItem {
            const self = gobject.ext.newInstance(CommandStatsItem, .{});
            self.command = try alloc.dupeZ(u8, command);
            errdefer alloc.free(self.command);
            self.execution_time_ms = execution_time_ms;
            self.memory_usage_kb = memory_usage_kb;
            self.cpu_percent = cpu_percent;
            self.success_rate = success_rate;
            self.run_count = run_count;
            return self;
        }

        pub fn deinit(self: *CommandStatsItem, alloc: Allocator) void {
            alloc.free(self.command);
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
        .name = "GhosttyPerformanceAnalyticsDialog",
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

        self.as(adw.PreferencesWindow).setTitle("Performance Analytics");
        self.as(adw.PreferencesWindow).setDefaultSize(800, 600);

        const page = adw.PreferencesPage.new();
        page.setTitle("Command Performance");
        page.setIconName("system-run-symbolic");

        // Statistics summary
        const stats_group = adw.PreferencesGroup.new();
        stats_group.setTitle("Summary Statistics");
        stats_group.setDescription("Overall performance metrics");

        const stats_label = gtk.Label.new("No data available");
        stats_label.setSelectable(@intFromBool(true));
        stats_label.setWrap(@intFromBool(true));
        priv.stats_label = stats_label;
        stats_group.add(stats_label.as(gtk.Widget));

        const refresh_btn = gtk.Button.new();
        refresh_btn.setLabel("Refresh Data");
        refresh_btn.setIconName("view-refresh-symbolic");
        priv.refresh_btn = refresh_btn;
        _ = refresh_btn.connectClicked(&refreshData, self);
        stats_group.add(refresh_btn.as(gtk.Widget));

        page.add(stats_group.as(gtk.Widget));

        // Commands list
        const commands_group = adw.PreferencesGroup.new();
        commands_group.setTitle("Command Performance");
        commands_group.setDescription("Detailed performance metrics by command");

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
        scrolled.setMinContentHeight(400);

        const commands_store = gio.ListStore.new(CommandStatsItem.getGObjectType());
        priv.commands_store = commands_store;

        const selection = gtk.SingleSelection.new(commands_store.as(gio.ListModel));
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupCommandStatsItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindCommandStatsItem, null, .{});

        const commands_list = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        priv.commands_list = commands_list;
        scrolled.setChild(commands_list.as(gtk.Widget));
        commands_group.add(scrolled.as(gtk.Widget));

        page.add(commands_group.as(gtk.Widget));
        self.as(adw.PreferencesWindow).add(page.as(adw.PreferencesPage));
    }

    fn setupCommandStatsItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.vertical, 4);
        box.setMarginStart(8);
        box.setMarginEnd(8);
        box.setMarginTop(4);
        box.setMarginBottom(4);

        const command_label = gtk.Label.new("");
        command_label.setXalign(0);
        command_label.getStyleContext().addClass("monospace");
        command_label.getStyleContext().addClass("heading");
        box.append(command_label.as(gtk.Widget));

        const stats_box = gtk.Box.new(gtk.Orientation.horizontal, 12);
        const time_label = gtk.Label.new("");
        time_label.setXalign(0);
        stats_box.append(time_label.as(gtk.Widget));

        const memory_label = gtk.Label.new("");
        memory_label.setXalign(0);
        stats_box.append(memory_label.as(gtk.Widget));

        const cpu_label = gtk.Label.new("");
        cpu_label.setXalign(0);
        stats_box.append(cpu_label.as(gtk.Widget));

        const success_label = gtk.Label.new("");
        success_label.setXalign(0);
        stats_box.append(success_label.as(gtk.Widget));

        box.append(stats_box.as(gtk.Widget));
        item.setChild(box.as(gtk.Widget));
    }

    fn bindCommandStatsItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const stats_item = @as(*CommandStatsItem, @ptrCast(entry));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |command| {
            command.as(gtk.Label).setText(stats_item.command);
            if (command.getNextSibling()) |stats_box| {
                const alloc = Application.default().allocator();
                const time_text = std.fmt.allocPrintZ(alloc, "Time: {d}ms", .{stats_item.execution_time_ms}) catch return;
                defer alloc.free(time_text);
                const memory_text = std.fmt.allocPrintZ(alloc, "Memory: {d}KB", .{stats_item.memory_usage_kb}) catch return;
                defer alloc.free(memory_text);
                const cpu_text = std.fmt.allocPrintZ(alloc, "CPU: {d:.1}%", .{stats_item.cpu_percent}) catch return;
                defer alloc.free(cpu_text);
                const success_text = std.fmt.allocPrintZ(alloc, "Success: {d:.1}%", .{stats_item.success_rate * 100.0}) catch return;
                defer alloc.free(success_text);

                const stats_box_widget = stats_box.as(gtk.Box);
                if (stats_box_widget.getFirstChild()) |time| {
                    time.as(gtk.Label).setText(time_text);
                    if (time.getNextSibling()) |memory| {
                        memory.as(gtk.Label).setText(memory_text);
                        if (memory.getNextSibling()) |cpu| {
                            cpu.as(gtk.Label).setText(cpu_text);
                            if (cpu.getNextSibling()) |success| {
                                success.as(gtk.Label).setText(success_text);
                            }
                        }
                    }
                }
            }
        }
    }

    fn refreshData(button: *gtk.Button, self: *Self) callconv(.c) void {
        _ = button;
        const priv = getPriv(self);
        _ = Application.default().allocator();

        // TODO: Implement actual data refresh
        log.info("Refreshing performance data...", .{});

        // Update stats label
        if (priv.stats_label) |label| {
            label.setText("Performance data refreshed");
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);

        // Clean up all stats items - just removeAll, GObject dispose handles item cleanup
        if (priv.commands_store) |store| {
            store.removeAll();
        }

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.PreferencesWindow).setTransientFor(parent.as(gtk.Window));
        self.as(adw.PreferencesWindow).present();
    }
};
