//! Workflows Management Dialog
//! Provides UI for creating, editing, and executing AI workflows

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

const log = std.log.scoped(.gtk_ghostty_ai_workflows);

const WorkflowManager = @import("../../../ai/workflows.zig").WorkflowManager;
const Workflow = @import("../../../ai/workflows.zig").Workflow;

pub const WorkflowsDialog = extern struct {
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
        workflow_manager: ?WorkflowManager = null,
        workflows_list: ?*gtk.ListView = null,
        workflows_store: ?*gio.ListStore = null,
        name_entry: ?*gtk.Entry = null,
        description_entry: ?*gtk.TextView = null,
        commands_text: ?*gtk.TextView = null,
        create_btn: ?*gtk.Button = null,
        execute_btn: ?*gtk.Button = null,
        delete_btn: ?*gtk.Button = null,

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

        // Initialize workflow manager
        priv.workflow_manager = WorkflowManager.init(alloc) catch |err| {
            log.err("Failed to initialize workflow manager: {}", .{err});
            priv.workflow_manager = null;
        };

        // Create UI (simplified - full implementation would use blueprint)
        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        const title = gtk.Label.new("AI Workflows");
        const title_ctx = title.getStyleContext();
        title_ctx.addClass("heading");
        box.append(title.as(gtk.Widget));

        const info = gtk.Label.new("Create reusable command sequences");
        const info_ctx = info.getStyleContext();
        info_ctx.addClass("dim-label");
        box.append(info.as(gtk.Widget));

        self.as(adw.Window).setContent(box.as(gtk.Widget));
        self.as(adw.Window).setTitle("Workflows");
        self.as(adw.Window).setDefaultSize(600, 400);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.workflow_manager) |*wm| {
            wm.deinit();
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).setModal(@intFromBool(true));
        self.as(adw.Window).present();
    }
};
