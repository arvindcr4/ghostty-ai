//! Command History Dialog
//! Provides UI for viewing and searching rich command history

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

const log = std.log.scoped(.gtk_ghostty_ai_history);

const RichHistoryManager = @import("../../../ai/rich_history.zig").RichHistoryManager;

pub const HistoryDialog = extern struct {
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
        history_manager: ?RichHistoryManager = null,
        history_list: ?*gtk.ListView = null,
        history_store: ?*gio.ListStore = null,
        search_entry: ?*gtk.SearchEntry = null,

        pub var offset: c_int = 0;
    };

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Initialize history manager
        priv.history_manager = RichHistoryManager.init(alloc, 1000) catch |err| {
            log.err("Failed to initialize history manager: {}", .{err});
            priv.history_manager = null;
        };

        // Create UI
        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        const title = gtk.Label.new("Command History");
        const title_ctx = title.getStyleContext();
        title_ctx.addClass("heading");
        box.append(title.as(gtk.Widget));

        const info = gtk.Label.new("View and search your command history");
        const info_ctx = info.getStyleContext();
        info_ctx.addClass("dim-label");
        box.append(info.as(gtk.Widget));

        self.as(adw.Window).setContent(box.as(gtk.Widget));
        self.as(adw.Window).setTitle("Command History");
        self.as(adw.Window).setDefaultSize(800, 600);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.history_manager) |*hm| {
            hm.deinit();
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).setModal(@intFromBool(true));
        self.as(adw.Window).present();
    }
};
