//! Visual Diff Viewer
//! Provides Warp-like diff viewer for comparing command outputs

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

const log = std.log.scoped(.gtk_ghostty_diff_viewer);

pub const DiffViewerDialog = extern struct {
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
        left_text: ?*gtk.TextView = null,
        right_text: ?*gtk.TextView = null,
        diff_text: ?*gtk.TextView = null,
        left_label: ?*gtk.Label = null,
        right_label: ?*gtk.Label = null,

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

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyDiffViewerDialog",
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

        self.as(adw.Window).setTitle("Diff Viewer");
        self.as(adw.Window).setDefaultSize(1000, 600);

        const box = gtk.Box.new(gtk.Orientation.vertical, 12);
        box.setMarginStart(12);
        box.setMarginEnd(12);
        box.setMarginTop(12);
        box.setMarginBottom(12);

        // Header with labels
        const header = gtk.Box.new(gtk.Orientation.horizontal, 12);
        const left_label = gtk.Label.new("Original");
        left_label.setXalign(0);
        left_label.getStyleContext().addClass("heading");
        priv.left_label = left_label;
        header.append(left_label.as(gtk.Widget));

        const right_label = gtk.Label.new("Modified");
        right_label.setXalign(0);
        right_label.getStyleContext().addClass("heading");
        priv.right_label = right_label;
        header.append(right_label.as(gtk.Widget));
        box.append(header.as(gtk.Widget));

        // Split view for side-by-side comparison
        const paned = gtk.Paned.new(gtk.Orientation.horizontal);

        // Left side (original)
        const left_scrolled = gtk.ScrolledWindow.new();
        left_scrolled.setPolicy(gtk.PolicyType.automatic, gtk.PolicyType.automatic);
        const left_buffer = gtk.TextBuffer.new(null);
        const left_view = gtk.TextView.newWithBuffer(left_buffer);
        left_view.setEditable(@intFromBool(false));
        left_view.setMonospace(@intFromBool(true));
        priv.left_text = left_view;
        left_scrolled.setChild(left_view.as(gtk.Widget));
        paned.setStartChild(left_scrolled.as(gtk.Widget));

        // Right side (modified)
        const right_scrolled = gtk.ScrolledWindow.new();
        right_scrolled.setPolicy(gtk.PolicyType.automatic, gtk.PolicyType.automatic);
        const right_buffer = gtk.TextBuffer.new(null);
        const right_view = gtk.TextView.newWithBuffer(right_buffer);
        right_view.setEditable(@intFromBool(false));
        right_view.setMonospace(@intFromBool(true));
        priv.right_text = right_view;
        right_scrolled.setChild(right_view.as(gtk.Widget));
        paned.setEndChild(right_scrolled.as(gtk.Widget));

        paned.setPosition(500); // Split in the middle
        box.append(paned.as(gtk.Widget));

        // Unified diff view (optional)
        const diff_label = gtk.Label.new("Unified Diff");
        diff_label.setXalign(0);
        diff_label.getStyleContext().addClass("heading");
        box.append(diff_label.as(gtk.Widget));

        const diff_scrolled = gtk.ScrolledWindow.new();
        diff_scrolled.setMinContentHeight(150);
        diff_scrolled.setPolicy(gtk.PolicyType.automatic, gtk.PolicyType.automatic);
        const diff_buffer = gtk.TextBuffer.new(null);
        const diff_view = gtk.TextView.newWithBuffer(diff_buffer);
        diff_view.setEditable(@intFromBool(false));
        diff_view.setMonospace(@intFromBool(true));
        priv.diff_text = diff_view;
        diff_scrolled.setChild(diff_view.as(gtk.Widget));
        box.append(diff_scrolled.as(gtk.Widget));

        self.as(adw.Window).setContent(box.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn setLeftText(self: *Self, text: []const u8) void {
        const priv = getPriv(self);
        if (priv.left_text) |view| {
            const buffer = view.getBuffer();
            const text_z = std.fmt.allocPrintZ(Application.default().allocator(), "{s}", .{text}) catch return;
            defer Application.default().allocator().free(text_z);
            buffer.setText(text_z, -1);
        }
    }

    pub fn setRightText(self: *Self, text: []const u8) void {
        const priv = getPriv(self);
        if (priv.right_text) |view| {
            const buffer = view.getBuffer();
            const text_z = std.fmt.allocPrintZ(Application.default().allocator(), "{s}", .{text}) catch return;
            defer Application.default().allocator().free(text_z);
            buffer.setText(text_z, -1);
        }
    }

    pub fn setDiffText(self: *Self, text: []const u8) void {
        const priv = getPriv(self);
        if (priv.diff_text) |view| {
            const buffer = view.getBuffer();
            const text_z = std.fmt.allocPrintZ(Application.default().allocator(), "{s}", .{text}) catch return;
            defer Application.default().allocator().free(text_z);
            buffer.setText(text_z, -1);
        }
    }

    pub fn setLabels(self: *Self, left: []const u8, right: []const u8) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();
        if (priv.left_label) |label| {
            const left_z = alloc.dupeZ(u8, left) catch return;
            defer alloc.free(left_z);
            label.setText(left_z);
        }
        if (priv.right_label) |label| {
            const right_z = alloc.dupeZ(u8, right) catch return;
            defer alloc.free(right_z);
            label.setText(right_z);
        }
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.Window).setTransientFor(parent.as(gtk.Window));
        self.as(adw.Window).present();
    }
};
