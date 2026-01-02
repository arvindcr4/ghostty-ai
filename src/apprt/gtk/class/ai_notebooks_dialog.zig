//! Notebooks Management Dialog
//! Provides UI for creating, editing, and executing notebooks

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

const log = std.log.scoped(.gtk_ghostty_ai_notebooks);

const NotebookManager = @import("../../../ai/notebooks.zig").NotebookManager;
const Notebook = @import("../../../ai/notebooks.zig").Notebook;

pub const NotebooksDialog = extern struct {
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
        notebook_manager: ?NotebookManager = null,
        notebooks_list: ?*gtk.ListView = null,
        notebooks_store: ?*gio.ListStore = null,

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
        return self.refSink();
    }

    fn init(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Initialize notebook manager
        priv.notebook_manager = NotebookManager.init(alloc) catch |err| {
            log.err("Failed to initialize notebook manager: {}", .{err});
            priv.notebook_manager = null;
        };

        // Create UI
        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        const title = gtk.Label.new("AI Notebooks");
        const title_ctx = title.getStyleContext();
        title_ctx.addClass("heading");
        box.append(title.as(gtk.Widget));

        const info = gtk.Label.new("Create executable documentation notebooks");
        const info_ctx = info.getStyleContext();
        info_ctx.addClass("dim-label");
        box.append(info.as(gtk.Widget));

        self.as(adw.Window).setContent(box.as(gtk.Widget));
        self.as(adw.Window).setTitle("Notebooks");
        self.as(adw.Window).setDefaultSize(700, 500);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.notebook_manager) |*nm| {
            nm.deinit();
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).setModal(@intFromBool(true));
        self.as(adw.Window).present();
    }
};
