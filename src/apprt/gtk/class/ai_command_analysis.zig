//! Command Output Analysis UI
//! Provides Warp-like analysis of command outputs with AI insights

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

const log = std.log.scoped(.gtk_ghostty_command_analysis);

pub const CommandAnalysisDialog = extern struct {
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
        command_text: ?*gtk.Label = null,
        output_text: ?*gtk.TextView = null,
        analysis_text: ?*gtk.TextView = null,
        analyze_btn: ?*gtk.Button = null,
        insights_list: ?*gtk.ListView = null,
        insights_store: ?*gio.ListStore = null,

        pub var offset: c_int = 0;
    };

    pub const InsightItem = extern struct {
        parent_instance: gobject.Object,
        title: []const u8,
        description: []const u8,
        severity: InsightSeverity,

        pub const Parent = gobject.Object;
        pub const InsightSeverity = enum {
            info,
            warning,
            err,
            success,
        };

        pub const getGObjectType = gobject.ext.defineClass(InsightItem, .{
            .name = "GhosttyInsightItem",
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

        pub fn new(alloc: Allocator, title: []const u8, description: []const u8, severity: InsightSeverity) !*InsightItem {
            const self = gobject.ext.newInstance(InsightItem, .{});
            self.title = try alloc.dupe(u8, title);
            errdefer alloc.free(self.title);
            self.description = try alloc.dupe(u8, description);
            errdefer alloc.free(self.description);
            self.severity = severity;
            return self;
        }

        pub fn deinit(self: *InsightItem, alloc: Allocator) void {
            alloc.free(self.title);
            alloc.free(self.description);
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
        .name = "GhosttyCommandAnalysisDialog",
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

        self.as(adw.Window).setTitle("Command Output Analysis");
        self.as(adw.Window).setDefaultSize(800, 600);

        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        // Command label
        const command_label = gtk.Label.new("");
        command_label.setXalign(0);
        command_label.getStyleContext().addClass("heading");
        priv.command_text = command_label;
        box.append(command_label.as(gtk.Widget));

        // Output text view
        const output_scrolled = gtk.ScrolledWindow.new();
        output_scrolled.setMinContentHeight(150);
        output_scrolled.setPolicy(gtk.PolicyType.automatic, gtk.PolicyType.automatic);

        const output_buffer = gtk.TextBuffer.new(null);
        const output_view = gtk.TextView.newWithBuffer(output_buffer);
        output_view.setEditable(@intFromBool(false));
        output_view.setMonospace(@intFromBool(true));
        priv.output_text = output_view;
        output_scrolled.setChild(output_view.as(gtk.Widget));
        box.append(output_scrolled.as(gtk.Widget));

        // Analyze button
        const analyze_btn = gtk.Button.new();
        analyze_btn.setLabel("Analyze with AI");
        analyze_btn.setIconName("system-search-symbolic");
        priv.analyze_btn = analyze_btn;
        _ = analyze_btn.connectClicked(&analyzeOutput, self);
        box.append(analyze_btn.as(gtk.Widget));

        // Analysis text view
        const analysis_scrolled = gtk.ScrolledWindow.new();
        analysis_scrolled.setMinContentHeight(150);
        analysis_scrolled.setPolicy(gtk.PolicyType.automatic, gtk.PolicyType.automatic);

        const analysis_buffer = gtk.TextBuffer.new(null);
        const analysis_view = gtk.TextView.newWithBuffer(analysis_buffer);
        analysis_view.setEditable(@intFromBool(false));
        priv.analysis_text = analysis_view;
        analysis_scrolled.setChild(analysis_view.as(gtk.Widget));
        box.append(analysis_scrolled.as(gtk.Widget));

        // Insights list
        const insights_label = gtk.Label.new("Key Insights");
        insights_label.setXalign(0);
        insights_label.getStyleContext().addClass("heading");
        box.append(insights_label.as(gtk.Widget));

        const insights_scrolled = gtk.ScrolledWindow.new();
        insights_scrolled.setMinContentHeight(100);
        insights_scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);

        const insights_store = gio.ListStore.new(InsightItem.getGObjectType());
        priv.insights_store = insights_store;

        const selection = gtk.NoSelection.new(insights_store.as(gio.ListModel));
        const factory = gtk.SignalListItemFactory.new();
        _ = factory.connectSetup(*anyopaque, &setupInsightItem, null, .{});
        _ = factory.connectBind(*anyopaque, &bindInsightItem, null, .{});

        const insights_list = gtk.ListView.new(selection.as(gtk.SelectionModel), factory.as(gtk.ListItemFactory));
        priv.insights_list = insights_list;
        insights_scrolled.setChild(insights_list.as(gtk.Widget));
        box.append(insights_scrolled.as(gtk.Widget));

        self.as(adw.Window).setContent(box.as(gtk.Widget));
    }

    fn setupInsightItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const box = gtk.Box.new(gtk.Orientation.vertical, 4);
        box.setMarginStart(8);
        box.setMarginEnd(8);
        box.setMarginTop(4);
        box.setMarginBottom(4);

        const title_label = gtk.Label.new("");
        title_label.setXalign(0);
        title_label.getStyleContext().addClass("heading");
        box.append(title_label.as(gtk.Widget));

        const desc_label = gtk.Label.new("");
        desc_label.setXalign(0);
        desc_label.setWrap(@intFromBool(true));
        box.append(desc_label.as(gtk.Widget));

        item.setChild(box.as(gtk.Widget));
    }

    fn bindInsightItem(_: *gtk.SignalListItemFactory, item: *gtk.ListItem, _: ?*anyopaque) callconv(.c) void {
        const entry = item.getItem() orelse return;
        const insight_item = @as(*InsightItem, @ptrCast(entry));
        const box = item.getChild() orelse return;
        const box_widget = box.as(gtk.Box);

        if (box_widget.getFirstChild()) |title| {
            title.as(gtk.Label).setText(insight_item.title);
            if (title.getNextSibling()) |desc| {
                desc.as(gtk.Label).setText(insight_item.description);
            }
        }
    }

    fn analyzeOutput(button: *gtk.Button, self: *Self) callconv(.c) void {
        _ = button;
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // TODO: Implement actual AI analysis
        log.info("Analyzing command output...", .{});

        // Example: Add sample insights
        if (priv.insights_store) |store| {
            const insight1 = InsightItem.new(alloc, "Performance", "Command completed successfully", .success) catch return;
            store.append(insight1.as(gobject.Object));

            const insight2 = InsightItem.new(alloc, "Warning", "Large output detected", .warning) catch return;
            store.append(insight2.as(gobject.Object));
        }
    }

    pub fn setCommand(self: *Self, command: []const u8) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();
        if (priv.command_text) |label| {
            const command_z = alloc.dupeZ(u8, command) catch return;
            defer alloc.free(command_z);
            label.setText(command_z);
        }
    }

    pub fn setOutput(self: *Self, output: []const u8) void {
        const priv = getPriv(self);
        if (priv.output_text) |view| {
            const buffer = view.getBuffer();
            const output_z = std.fmt.allocPrintZ(Application.default().allocator(), "{s}", .{output}) catch return;
            defer Application.default().allocator().free(output_z);
            buffer.setText(output_z, -1);
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Clean up all insight items
        if (priv.insights_store) |store| {
            const n = store.getNItems();
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (store.getItem(i)) |item| {
                    const insight_item: *InsightItem = @ptrCast(@alignCast(item));
                    insight_item.deinit(alloc);
                }
            }
        }

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).present();
    }
};
