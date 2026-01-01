//! AI Command Search Widget
//!
//! This widget provides natural language command search functionality,
//! similar to Warp Terminal's '#' feature. Users can type a natural language
//! query to find or generate relevant commands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Config = @import("config.zig").Config;
const gresource = @import("../build/gresource.zig");

const AiAssistant = @import("../../../ai/main.zig").Assistant;

const log = std.log.scoped(.ai_command_search);

/// Command suggestion shown in the results list.
pub const CommandSuggestion = extern struct {
    const Self = @This();
    pub const Parent = gobject.Object;

    parent_instance: Parent,

    const Private = struct {
        arena: ArenaAllocator,
        command: ?[:0]const u8 = null,
        explanation: ?[:0]const u8 = null,
        context: ?[:0]const u8 = null,
        has_context: bool = false,

        pub var offset: c_int = 0;
    };

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

        pub const explanation = struct {
            pub const name = "explanation";
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
                            .getter = propGetExplanation,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const context = struct {
            pub const name = "context";
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
                            .getter = propGetContext,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const has_context = struct {
            pub const name = "has-context";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = propGetHasContext,
                        },
                    ),
                },
            );
        };
    };

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommandSuggestion",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub fn new(command: []const u8, explanation: []const u8, context: []const u8) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = private(self);

        const alloc = priv.arena.allocator();
        priv.command = alloc.dupeZ(u8, command) catch null;
        priv.explanation = alloc.dupeZ(u8, explanation) catch null;
        priv.context = if (context.len > 0) alloc.dupeZ(u8, context) catch null else null;
        priv.has_context = context.len > 0;

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        private(self).arena = .init(Application.default().allocator());
    }

    fn finalize(self: *Self) callconv(.c) void {
        private(self).arena.deinit();
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    fn propGetCommand(self: *Self) ?[:0]const u8 {
        return private(self).command;
    }

    fn propGetExplanation(self: *Self) ?[:0]const u8 {
        return private(self).explanation;
    }

    fn propGetContext(self: *Self) ?[:0]const u8 {
        return private(self).context;
    }

    fn propGetHasContext(self: *Self) bool {
        return private(self).has_context;
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
                properties.explanation.impl,
                properties.context.impl,
                properties.has_context.impl,
            });

            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};

/// AI Command Search Widget
pub const AiCommandSearch = extern struct {
    const Self = @This();
    const C = Common(Self, Private);

    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    pub const refSink = C.refSink;
    const private = C.private;

    parent_instance: Parent,

    pub const Parent = adw.Bin;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyAiCommandSearch",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        // Configuration & state
        config: ?*Config = null,
        assistant: ?AiAssistant = null,
        window: ?*Window = null,
        terminal_history: ?[]u8 = null,

        // GTK components
        dialog: *adw.Dialog,
        search_entry: *gtk.Entry,
        results_list: *gtk.ListView,
        results_store: *gio.ListStore,
        loading_label: *gtk.Label,
        no_results_label: *gtk.Label,

        pub var offset: c_int = 0;
    };

    const SearchThreadContext = struct {
        widget: *AiCommandSearch,
        query: []const u8,
        history: ?[]const u8,
        assistant: ?AiAssistant,
    };

    const SearchResult = struct {
        widget: *AiCommandSearch,
        response: ?[:0]const u8,
        err: ?[:0]const u8,
    };

    /// Create a new AI command search instance
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = private(self);
        priv.* = .{};
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn setConfig(self: *Self, config: *Config) void {
        const priv = private(self);
        priv.config = config;

        const cfg = config.get();

        if (!cfg.@"ai-enabled") {
            priv.assistant = null;
            return;
        }

        const provider = cfg.@"ai-provider" orelse {
            priv.assistant = null;
            return;
        };

        const provider_enum: AiAssistant.Provider = switch (provider) {
            .openai => .openai,
            .anthropic => .anthropic,
            .ollama => .ollama,
            .custom => .custom,
        };

        const ai_config = AiAssistant.Config{
            .enabled = cfg.@"ai-enabled",
            .provider = provider_enum,
            .api_key = cfg.@"ai-api-key",
            .endpoint = cfg.@"ai-endpoint",
            .model = cfg.@"ai-model",
            .max_tokens = cfg.@"ai-max-tokens",
            .temperature = cfg.@"ai-temperature",
            .context_aware = cfg.@"ai-context-aware",
            .context_lines = cfg.@"ai-context-lines",
            .system_prompt = cfg.@"ai-system-prompt",
        };

        const alloc = Application.default().allocator();
        priv.assistant = AiAssistant.init(alloc, ai_config) catch null;
    }

    /// Show the command search dialog
    pub fn show(self: *Self, win: *Window) void {
        const priv = private(self);
        priv.window = win;

        // Refresh terminal history snapshot
        if (priv.terminal_history) |hist| {
            Application.default().allocator().free(hist);
            priv.terminal_history = null;
        }

        if (priv.config) |config| {
            const cfg = config.get();
            if (cfg.@"ai-context-aware") {
                const surface = win.getActiveSurface() orelse {
                    priv.terminal_history = null;
                    priv.dialog.present(win.as(gtk.Widget));
                    _ = priv.search_entry.as(gtk.Widget).grabFocus();
                    return;
                };
                const core_surface = surface.core() orelse {
                    priv.terminal_history = null;
                    priv.dialog.present(win.as(gtk.Widget));
                    _ = priv.search_entry.as(gtk.Widget).grabFocus();
                    return;
                };
                priv.terminal_history = core_surface.getTerminalHistory(
                    Application.default().allocator(),
                    cfg.@"ai-context-lines",
                ) catch null;
            }
        }

        // Reset UI state
        clearResults(self);
        priv.loading_label.setVisible(false);
        priv.no_results_label.setVisible(false);
        priv.search_entry.setText("");

        // Present
        priv.dialog.present(win.as(gtk.Widget));
        _ = priv.search_entry.as(gtk.Widget).grabFocus();
    }

    fn clearResults(self: *Self) void {
        const priv = private(self);
        const n: c_uint = @intCast(priv.results_store.nItems());
        if (n > 0) priv.results_store.remove(0, n);
    }

    fn closed(_: *adw.Dialog, self: *Self) callconv(.c) void {
        const priv = private(self);
        clearResults(self);
        priv.loading_label.setVisible(false);
        priv.no_results_label.setVisible(false);

        if (priv.terminal_history) |hist| {
            Application.default().allocator().free(hist);
            priv.terminal_history = null;
        }

        priv.window = null;
    }

    fn close(_: *gtk.Button, self: *Self) callconv(.c) void {
        private(self).dialog.forceClose();
    }

    fn search_changed(_: *gtk.Entry, self: *Self) callconv(.c) void {
        const priv = private(self);
        priv.no_results_label.setVisible(false);
    }

    fn search_activated(entry: *gtk.Entry, self: *Self) callconv(.c) void {
        const alloc = Application.default().allocator();
        const priv = private(self);

        const query = std.mem.trim(u8, std.mem.span(entry.as(gtk.Editable).getText()), &std.ascii.whitespace);
        if (query.len == 0) return;

        clearResults(self);
        priv.no_results_label.setVisible(false);
        priv.loading_label.setVisible(true);

        const query_copy = alloc.dupe(u8, query) catch return;
        const history_copy = if (priv.terminal_history) |h| alloc.dupe(u8, h) catch null else null;

        const ctx = SearchThreadContext{
            .widget = self,
            .query = query_copy,
            .history = history_copy,
            .assistant = priv.assistant,
        };

        _ = self.ref();
        const thread = std.Thread.spawn(.{}, searchThreadMain, .{ctx}) catch |err| {
            log.err("Failed to spawn search thread: {}", .{err});
            alloc.free(query_copy);
            if (history_copy) |h| alloc.free(h);
            self.unref();
            priv.loading_label.setVisible(false);
            return;
        };
        thread.detach();
    }

    fn searchThreadMain(ctx: SearchThreadContext) void {
        const alloc = Application.default().allocator();
        defer alloc.free(ctx.query);
        defer if (ctx.history) |h| alloc.free(h);

        const response_z: ?[:0]const u8 = response: {
            if (ctx.assistant) |assistant| {
                const prompt = std.fmt.allocPrint(
                    alloc,
                    \\Search or generate the best matching shell commands for this query:
                    \\
                    \\Query: "{s}"
                    \\
                    \\Return up to 10 results, one per line, in the format:
                    \\- <command> :: <one sentence explanation>
                    ,
                    .{ctx.query},
                ) catch break :response null;
                defer alloc.free(prompt);

                const result = assistant.process(prompt, ctx.history) catch break :response null;
                defer result.deinit(alloc);
                break :response alloc.dupeZ(u8, result.content) catch null;
            }

            if (ctx.history) |history| {
                break :response localSearch(alloc, history, ctx.query);
            }

            break :response alloc.dupeZ(u8, "") catch null;
        };

        const out = alloc.create(SearchResult) catch {
            if (response_z) |r| alloc.free(r);
            ctx.widget.unref();
            return;
        };
        out.* = .{
            .widget = ctx.widget,
            .response = response_z,
            .err = null,
        };

        _ = glib.idleAdd(searchResultCallback, out);
    }

    fn localSearch(alloc: Allocator, history: []const u8, query: []const u8) ?[:0]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(alloc);

        var seen = std.StringHashMapUnmanaged(void){};
        defer seen.deinit(alloc);

        const lower_query = std.ascii.allocLowerString(alloc, query) catch return null;
        defer alloc.free(lower_query);

        var count: usize = 0;
        var it = std.mem.splitScalar(u8, history, '\n');
        while (it.next()) |line| {
            if (count >= 10) break;
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            const cmd = extractPromptCommand(trimmed) orelse continue;

            const lower_cmd = std.ascii.allocLowerString(alloc, cmd) catch continue;
            defer alloc.free(lower_cmd);

            if (std.mem.indexOf(u8, lower_cmd, lower_query) == null) continue;

            // Dedup commands
            const key = alloc.dupe(u8, cmd) catch continue;
            if (seen.get(key) != null) {
                alloc.free(key);
                continue;
            }
            seen.put(alloc, key, {}) catch {
                alloc.free(key);
                continue;
            };

            out.writer(alloc).print("- {s} :: from terminal history\n", .{cmd}) catch break;
            count += 1;
        }

        if (out.items.len == 0) return alloc.dupeZ(u8, "") catch null;
        return out.toOwnedSliceSentinel(alloc, 0) catch null;
    }

    fn extractPromptCommand(line: []const u8) ?[]const u8 {
        const prefixes = [_][]const u8{ "$ ", "> ", "❯ ", "# " };
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, line, p)) return std.mem.trimLeft(u8, line[p.len..], &std.ascii.whitespace);
        }
        return null;
    }

    fn searchResultCallback(data: ?*anyopaque) callconv(.c) c_int {
        const res: *SearchResult = @ptrCast(@alignCast(data));
        const alloc = Application.default().allocator();
        defer alloc.destroy(res);
        defer if (res.response) |r| alloc.free(r);
        defer if (res.err) |e| alloc.free(e);

        const self = res.widget;
        defer self.unref();

        const priv = private(self);
        priv.loading_label.setVisible(false);
        clearResults(self);

        if (res.err) |err_msg| {
            priv.no_results_label.setLabel(err_msg);
            priv.no_results_label.setVisible(true);
            return 0;
        }

        const response = res.response orelse {
            priv.no_results_label.setVisible(true);
            return 0;
        };

        var any: bool = false;
        var lines = std.mem.splitScalar(u8, response, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            const without_bullet = if (std.mem.startsWith(u8, trimmed, "- ")) trimmed[2..] else trimmed;
            const sep = " :: ";
            const idx = std.mem.indexOf(u8, without_bullet, sep) orelse without_bullet.len;
            const cmd = std.mem.trim(u8, without_bullet[0..idx], &std.ascii.whitespace);
            if (cmd.len == 0) continue;

            const expl = if (idx < without_bullet.len)
                std.mem.trim(u8, without_bullet[idx + sep.len ..], &std.ascii.whitespace)
            else
                "";

            const suggestion = CommandSuggestion.new(cmd, expl, "");
            const obj = suggestion.as(gobject.Object);
            priv.results_store.append(obj);
            obj.unref();
            any = true;
        }

        priv.no_results_label.setVisible(!any);
        return 0;
    }

    fn suggestion_activated(_: *gtk.ListView, pos: c_uint, self: *Self) callconv(.c) void {
        const priv = private(self);
        const win = priv.window orelse return;

        const item = priv.results_store.getItem(pos) orelse return;
        defer item.unref();

        const suggestion: *CommandSuggestion = @ptrCast(@alignCast(item));
        const suggestion_priv = CommandSuggestion.private(suggestion);
        const cmd_z = suggestion_priv.command orelse return;
        const cmd = std.mem.span(cmd_z);
        if (cmd.len == 0) return;

        const surface = win.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;

        const alloc = Application.default().allocator();
        const cmd_nl = alloc.alloc(u8, cmd.len + 1) catch return;
        defer alloc.free(cmd_nl);
        @memcpy(cmd_nl[0..cmd.len], cmd);
        cmd_nl[cmd.len] = '\n';

        _ = core_surface.performBindingAction(.{ .text = cmd_nl }) catch |err| {
            log.err("Failed to execute command: {}", .{err});
            return;
        };

        priv.dialog.forceClose();
    }

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(CommandSuggestion);

            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "ai-command-search",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search_entry", .{});
            class.bindTemplateChildPrivate("results_list", .{});
            class.bindTemplateChildPrivate("results_store", .{});
            class.bindTemplateChildPrivate("loading_label", .{});
            class.bindTemplateChildPrivate("no_results_label", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("close", &close);
            class.bindTemplateCallback("search_changed", &search_changed);
            class.bindTemplateCallback("search_activated", &search_activated);
            class.bindTemplateCallback("suggestion_activated", &suggestion_activated);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

