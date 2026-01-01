const std = @import("std");
const Allocator = std.mem.Allocator;

const adw = @import("adw");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const CoreSurface = @import("../../../Surface.zig");

const log = std.log.scoped(.gtk_ghostty_blocks);

pub const BlocksDialog = extern struct {
    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const getPriv = C.getPriv;
    const Self = @This();

    parent_instance: Parent,

    pub const Parent = adw.Bin;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyBlocksDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const BlockData = struct {
        index: usize,
        prompt: [:0]const u8,
        command: [:0]const u8,
        output: [:0]const u8,

        fn deinit(self: *BlockData, alloc: Allocator) void {
            alloc.free(self.prompt);
            alloc.free(self.command);
            alloc.free(self.output);
            self.* = undefined;
        }
    };

    const Private = struct {
        dialog: *adw.Dialog,
        search_entry: *gtk.SearchEntry,
        input_toggle: *gtk.ToggleButton,
        output_toggle: *gtk.ToggleButton,
        list_view: *gtk.ListView,
        list_store: *gio.ListStore,
        empty_label: *gtk.Label,
        window: ?*Window = null,
        blocks: std.ArrayList(BlockData) = .empty,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        priv.* = .{};

        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();
        for (priv.blocks.items) |*block| block.deinit(alloc);
        priv.blocks.deinit(alloc);

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    /// Show the blocks dialog.
    pub fn show(self: *Self, win: *Window, surface: *CoreSurface) void {
        const priv = getPriv(self);
        priv.window = win;

        self.refreshBlocks(surface);
        priv.dialog.present(win.as(gtk.Widget));
        _ = priv.search_entry.as(gtk.Widget).grabFocus();
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        priv.dialog.forceClose();
    }

    fn close(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        priv.dialog.forceClose();
    }

    fn refresh_clicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const surface = priv.window orelse return;
        const core_surface = surface.getActiveSurface() orelse return;
        const core = core_surface.core() orelse return;
        self.refreshBlocks(core);
    }

    fn search_changed(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.applyFilter();
    }

    fn filter_toggled(_: *gtk.ToggleButton, self: *Self) callconv(.c) void {
        self.applyFilter();
    }

    fn refreshBlocks(self: *Self, surface: *CoreSurface) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        for (priv.blocks.items) |*block| block.deinit(alloc);
        priv.blocks.clearRetainingCapacity();

        var block_list = surface.getBlocks(alloc) catch |err| {
            log.warn("failed to load blocks err={}", .{err});
            self.applyFilter();
            return;
        };
        defer {
            for (block_list.items) |*block| block.deinit(alloc);
            block_list.deinit(alloc);
        }

        for (block_list.items) |block| {
            const prompt = alloc.dupeZ(u8, block.prompt) catch continue;
            const command = alloc.dupeZ(u8, block.command) catch {
                alloc.free(prompt);
                continue;
            };
            const output = alloc.dupeZ(u8, block.output) catch {
                alloc.free(prompt);
                alloc.free(command);
                continue;
            };
            priv.blocks.append(alloc, .{
                .index = block.index,
                .prompt = prompt,
                .command = command,
                .output = output,
            }) catch {
                alloc.free(prompt);
                alloc.free(command);
                alloc.free(output);
            };
        }

        self.applyFilter();
    }

    fn applyFilter(self: *Self) void {
        const priv = getPriv(self);

        priv.list_store.removeAll();

        const query_ptr = priv.search_entry.getText();
        const query = if (query_ptr) |q| std.mem.sliceTo(q, 0) else "";
        const match_input = priv.input_toggle.getActive() != 0;
        const match_output = priv.output_toggle.getActive() != 0;

        var matches: usize = 0;
        for (priv.blocks.items) |block| {
            if (!blockMatches(block, query, match_input, match_output)) continue;
            const item = BlockItem.new(block.index, block.command, block.prompt, block.output);
            priv.list_store.append(item);
            matches += 1;
        }

        priv.empty_label.setVisible(@intFromBool(matches == 0));
    }

    fn blockMatches(block: BlockData, query: []const u8, match_input: bool, match_output: bool) bool {
        if (query.len == 0) return true;
        if (!match_input and !match_output) return true;

        if (match_input) {
            if (containsCaseInsensitive(block.command, query) or containsCaseInsensitive(block.prompt, query)) {
                return true;
            }
        }

        if (match_output) {
            if (containsCaseInsensitive(block.output, query)) return true;
        }

        return false;
    }

    fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            var matched = true;
            for (needle, 0..) |c, j| {
                if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }

        return false;
    }

    const CClass = Common(Self, Private);
    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(BlockItem);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "blocks",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search_entry", .{});
            class.bindTemplateChildPrivate("input_toggle", .{});
            class.bindTemplateChildPrivate("output_toggle", .{});
            class.bindTemplateChildPrivate("list_view", .{});
            class.bindTemplateChildPrivate("list_store", .{});
            class.bindTemplateChildPrivate("empty_label", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("close", &close);
            class.bindTemplateCallback("search_changed", &search_changed);
            class.bindTemplateCallback("filter_toggled", &filter_toggled);
            class.bindTemplateCallback("refresh_clicked", &refresh_clicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = CClass.Class.as;
        pub const bindTemplateChildPrivate = CClass.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = CClass.Class.bindTemplateCallback;
    };
};

const BlockItem = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyBlockItem",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
        pub const command = struct {
            pub const name = "command";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetCommand,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const output_preview = struct {
            pub const name = "output-preview";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetOutputPreview,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        command: [:0]const u8 = "",
        output_preview: [:0]const u8 = "",
        command_owned: bool = false,
        output_preview_owned: bool = false,
        pub var offset: c_int = 0;
    };

    pub fn new(index: usize, command: [:0]const u8, prompt: [:0]const u8, output: [:0]const u8) *Self {
        _ = prompt;
        const alloc = Application.default().allocator();
        const item = gobject.ext.newInstance(Self, .{});
        const priv = gobject.ext.getPriv(item, &Private.offset);
        if (alloc.dupeZ(u8, command)) |command_copy| {
            priv.command = command_copy;
            priv.command_owned = true;
        } else |_| {
            priv.command = "";
            priv.command_owned = false;
        }

        const preview = buildPreview(alloc, output);
        priv.output_preview = preview.text;
        priv.output_preview_owned = preview.owned;
        _ = index;
        return item;
    }

    fn init(self: *Self) callconv(.c) void {
        const priv = gobject.ext.getPriv(self, &Private.offset);
        priv.* = .{};
    }

    fn propGetCommand(self: *Self) ?[:0]const u8 {
        return gobject.ext.getPriv(self, &Private.offset).command;
    }

    fn propGetOutputPreview(self: *Self) ?[:0]const u8 {
        return gobject.ext.getPriv(self, &Private.offset).output_preview;
    }

    const Preview = struct {
        text: [:0]const u8,
        owned: bool,
    };

    fn buildPreview(alloc: Allocator, output: [:0]const u8) Preview {
        var it = std.mem.splitScalar(u8, output, '\n');
        if (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len > 0) {
                if (alloc.dupeZ(u8, trimmed)) |text| {
                    return .{ .text = text, .owned = true };
                } else |_| {
                    return .{ .text = "", .owned = false };
                }
            }
        }

        if (alloc.dupeZ(u8, "")) |text| {
            return .{ .text = text, .owned = true };
        } else |_| {
            return .{ .text = "", .owned = false };
        }
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.registerProperties(class, &.{
                properties.command.impl,
                properties.output_preview.impl,
            });

            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };

    fn finalize(self: *Self) callconv(.c) void {
        const priv = gobject.ext.getPriv(self, &Private.offset);
        const alloc = Application.default().allocator();
        if (priv.command_owned) alloc.free(priv.command);
        if (priv.output_preview_owned) alloc.free(priv.output_preview);

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
};
