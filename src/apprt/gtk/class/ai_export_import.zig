//! Export/Import Dialogs
//! Provides Warp-like export/import functionality for AI data

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

const log = std.log.scoped(.gtk_ghostty_export_import);

pub const ExportImportDialog = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.MessageDialog;

    const Private = struct {
        export_type: ExportType = .chat_history,
        file_chooser: ?*gtk.FileChooserNative = null,

        pub var offset: c_int = 0;
    };

    pub const ExportType = enum {
        chat_history,
        notebooks,
        workflows,
        knowledge_rules,
        all_data,
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
        .name = "GhosttyExportImportDialog",
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
        _ = getPriv(self);
        self.as(adw.MessageDialog).setHeading("Export/Import Data");
        self.as(adw.MessageDialog).setBody("Choose what to export or import");
        self.as(adw.MessageDialog).setCloseResponse("cancel");
        self.as(adw.MessageDialog).setModal(@intFromBool(true));

        // Add action buttons
        self.addResponse("export", "Export");
        self.addResponse("import", "Import");
        self.addResponse("cancel", "Cancel");
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (priv.file_chooser) |chooser| {
            chooser.unref();
            priv.file_chooser = null;
        }
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    pub fn showExport(self: *Self, parent: *Window, export_type: ExportType) void {
        const priv = getPriv(self);
        priv.export_type = export_type;

        const chooser = gtk.FileChooserNative.new(
            "Export Data",
            parent.as(gtk.Window),
            gtk.FileChooserAction.save,
            "Export",
            "Cancel",
        );
        priv.file_chooser = chooser;

        // Set default filename based on export type
        const default_name = switch (export_type) {
            .chat_history => "ghostty-chat-history.json",
            .notebooks => "ghostty-notebooks.json",
            .workflows => "ghostty-workflows.json",
            .knowledge_rules => "ghostty-knowledge-rules.json",
            .all_data => "ghostty-all-data.json",
        };
        chooser.setCurrentName(default_name);

        // Add JSON filter
        const filter_json = gtk.FileFilter.new();
        filter_json.setName("JSON files");
        filter_json.addPattern("*.json");
        chooser.addFilter(filter_json);

        _ = chooser.connectResponse(&onExportResponse, self);
        chooser.show();
    }

    fn onExportResponse(chooser: *gtk.FileChooserNative, response_id: c_int, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        if (response_id == gtk.ResponseType.accept) {
            if (chooser.getFile()) |file| {
                defer file.unref();
                const path = file.getPath() orelse {
                    log.err("Failed to get file path", .{});
                    chooser.destroy();
                    priv.file_chooser = null;
                    return;
                };
                self.exportToFile(path, priv.export_type);
            }
        }
        chooser.destroy();
        priv.file_chooser = null;
    }

    fn exportToFile(self: *Self, path: []const u8, export_type: ExportType) void {
        _ = self;
        _ = Application.default().allocator();
        // TODO: Implement actual export logic
        log.info("Exporting {s} to {s}", .{ @tagName(export_type), path });
    }

    pub fn showImport(self: *Self, parent: *Window) void {
        const chooser = gtk.FileChooserNative.new(
            "Import Data",
            parent.as(gtk.Window),
            gtk.FileChooserAction.open,
            "Import",
            "Cancel",
        );

        // Add JSON filter
        const filter_json = gtk.FileFilter.new();
        filter_json.setName("JSON files");
        filter_json.addPattern("*.json");
        chooser.addFilter(filter_json);

        _ = chooser.connectResponse(&onImportResponse, self);
        chooser.show();
    }

    fn onImportResponse(chooser: *gtk.FileChooserNative, response_id: c_int, self: *Self) callconv(.c) void {
        if (response_id == gtk.ResponseType.accept) {
            if (chooser.getFile()) |file| {
                defer file.unref();
                const path = file.getPath() orelse {
                    log.err("Failed to get file path", .{});
                    chooser.destroy();
                    return;
                };
                self.importFromFile(path);
            }
        }
        chooser.destroy();
    }

    fn importFromFile(self: *Self, path: []const u8) void {
        _ = self;
        _ = Application.default().allocator();
        // TODO: Implement actual import logic
        log.info("Importing from {s}", .{path});
    }

    pub fn show(self: *Self, parent: *Window) void {
        self.as(adw.MessageDialog).setTransientFor(parent.as(gtk.Window));
        self.as(adw.MessageDialog).present();
    }
};
