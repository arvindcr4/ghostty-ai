//! Inline Error Explanation UI
//! Provides Warp-like inline error explanations for terminal errors

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

const log = std.log.scoped(.gtk_ghostty_error_explanation);

pub const ErrorExplanation = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.ToastOverlay;

    const Private = struct {
        error_text: ?[]const u8 = null,
        explanation_text: ?[]const u8 = null,
        fix_suggestions: std.ArrayList([]const u8),

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
        .name = "GhosttyErrorExplanation",
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
        const alloc = Application.default().allocator();
        priv.* = .{
            .fix_suggestions = std.ArrayList([]const u8).init(alloc),
        };
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        if (priv.error_text) |text| alloc.free(text);
        if (priv.explanation_text) |text| alloc.free(text);
        for (priv.fix_suggestions.items) |suggestion| {
            alloc.free(suggestion);
        }
        priv.fix_suggestions.deinit();

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn showError(self: *Self, error_text: []const u8, explanation: []const u8, fixes: []const []const u8) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Free old data
        if (priv.error_text) |old| alloc.free(old);
        if (priv.explanation_text) |old| alloc.free(old);
        for (priv.fix_suggestions.items) |suggestion| {
            alloc.free(suggestion);
        }
        priv.fix_suggestions.clearRetainingCapacity();

        // Store new data
        priv.error_text = alloc.dupe(u8, error_text) catch return;
        priv.explanation_text = alloc.dupe(u8, explanation) catch return;
        for (fixes) |fix| {
            const fix_dupe = alloc.dupe(u8, fix) catch continue;
            priv.fix_suggestions.append(fix_dupe) catch {
                alloc.free(fix_dupe);
            };
        }

        // Create toast with explanation and fix suggestions
        var toast_msg = std.ArrayList(u8).init(alloc);
        defer toast_msg.deinit();
        toast_msg.appendSlice(explanation) catch {};

        if (priv.fix_suggestions.items.len > 0) {
            toast_msg.appendSlice("\n\nSuggested fixes:") catch {};
            for (priv.fix_suggestions.items) |fix| {
                toast_msg.appendSlice("\n• ") catch {};
                toast_msg.appendSlice(fix) catch {};
            }
        }

        const toast_text = toast_msg.toOwnedSliceSentinel(0) catch {
            // If allocation fails, use original explanation
            const toast = adw.Toast.new(explanation);
            toast.setTimeout(10);
            self.addToast(toast);
            return;
        };
        defer alloc.free(toast_text);

        const toast = adw.Toast.new(toast_text);
        toast.setTimeout(10); // 10 seconds
        self.addToast(toast);
    }
};
