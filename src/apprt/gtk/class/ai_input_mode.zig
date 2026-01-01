const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_ai_input);

const AiAssistant = @import("../../../ai/main.zig").Assistant;
const HistoryManager = @import("../../../ai/history.zig").HistoryManager;
const ai_client = @import("../../../ai/client.zig");
const Binding = @import("../../../input/Binding.zig");
const PromptSuggestionService = @import("../../../ai/main.zig").PromptSuggestionService;
const PromptSuggestion = @import("../../../ai/main.zig").PromptSuggestion;

/// AI Input Mode Widget
///
/// This widget provides Warp-like AI features for Ghostty terminal.
/// It allows users to interact with an AI assistant for command explanation,
/// error debugging, workflow optimization, and more.
pub const AiInputMode = extern struct {
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
        .name = "GhosttyAiInputMode",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const send_sensitive = struct {
            pub const name = "send-sensitive";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateObjFieldAccessor("send_sensitive"),
                },
            );
        };

        pub const stop_sensitive = struct {
            pub const name = "stop-sensitive";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateObjFieldAccessor("stop_sensitive"),
                },
            );
        };

        pub const regenerate_sensitive = struct {
            pub const name = "regenerate-sensitive";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateObjFieldAccessor("regenerate_sensitive"),
                },
            );
        };
    };

    /// Response item for the AI response list
    pub const ResponseItem = extern struct {
        parent_instance: gobject.Object,

        content: [*:0]const u8,

        pub const ResponseItemParent = gobject.Object;
        pub const Parent = ResponseItemParent;

        pub const getGObjectType = gobject.ext.defineClass(@This(), .{
            .name = "GhosttyAiResponseItem",
            .instanceInit = &responseItemInit,
            .classInit = &ResponseItemClass.init,
            .parent_class = &ResponseItemClass.parent,
            .private = .{ .Type = ResponseItemPrivate, .offset = &ResponseItemPrivate.offset },
        });

        pub const ResponseItemPrivate = struct {
            content: [:0]const u8 = "",
            /// Extracted shell command from code blocks (if any)
            command: [:0]const u8 = "",
        };

        pub extern fn gtk_gesture_single_get_type() gobject.Type;
        pub extern fn gtk_event_controller_key_get_type() gobject.Type;

        fn responseItemInit(self: *@This()) callconv(.C) void {
            const priv = gobject.ext.getPriv(self, &ResponseItemPrivate.offset);
            priv.* = .{};
        }

        pub const ResponseItemClass = struct {
            parent: ResponseItemParent.Class,

            pub fn init(
                klass: *gobject.Class.Type,
                _: ?*anyopaque,
            ) callconv(.C) void {
                klass.parent = gobject.ext.initClass(ResponseItemParent, .{
                    .name = "GhosttyAiResponseItem",
                    .instance_size = @sizeOf(@This()),
                    .class_size = @sizeOf(ResponseItemClass),
                }).?;
            }
        };

        pub fn new(content: [:0]const u8, command: [:0]const u8) *@This() {
            const self = gobject.ext.newInstance(@This(), .{});
            const priv = gobject.ext.getPriv(self, &ResponseItemPrivate.offset);
            priv.content = content;
            priv.command = command;
            return self;
        }
    };

    const Private = struct {
        /// The configuration for this AI input mode
        config: ?*Config = null,

        /// The dialog containing the AI UI
        dialog: *adw.Dialog,

        /// Template dropdown for selecting prompt templates
        template_dropdown: *gtk.DropDown,

        /// Agent mode toggle
        agent_toggle: *gtk.ToggleButton,

        /// Text view for user input
        input_view: *gtk.TextView,

        /// Text buffer for input
        input_buffer: *gtk.TextBuffer,

        /// Response list view
        response_view: *gtk.ListView,

        /// Response store
        response_store: *gio.ListStore,

        /// Loading label
        loading_label: *gtk.Label,

        /// Context label
        context_label: *gtk.Label,

        /// Context chips container
        context_chips: *gtk.FlowBox,

        /// Selection chip
        selection_chip: *gtk.Box,

        /// History chip
        history_chip: *gtk.Box,

        /// Directory chip
        directory_chip: *gtk.Box,

        /// Directory label
        directory_label: *gtk.Label,

        /// Git chip
        git_chip: *gtk.Box,

        /// Git label
        git_label: *gtk.Label,

        /// Send button sensitivity
        send_sensitive: bool = false,

        /// Stop button sensitivity
        stop_sensitive: bool = false,

        /// Regenerate button sensitivity
        regenerate_sensitive: bool = false,

        /// Agent mode enabled
        agent_mode: bool = false,

        /// Last prompt for regeneration
        last_prompt: ?[]const u8 = null,

        /// Last context for regeneration
        last_context: ?[]const u8 = null,

        /// Request cancellation flag
        request_cancelled: bool = false,

        /// Selected text from terminal (for context)
        selected_text: ?[]const u8 = null,

        /// Terminal context (recent history)
        terminal_context: ?[]const u8 = null,

        /// AI Assistant instance
        assistant: ?AiAssistant = null,

        /// Current streaming response (accumulated content)
        streaming_response: ?std.ArrayList(u8) = null,

        /// Current streaming response item (for incremental updates)
        streaming_response_item: ?*ResponseItem = null,

        /// Reference to the window for command execution
        window: ?*Window = null,

        /// Prompt suggestion service
        prompt_suggestion_service: ?PromptSuggestionService = null,

        /// Suggestion popup window
        suggestion_popup: ?*gtk.Popover = null,

        /// Suggestion list box
        suggestion_list: ?*gtk.ListBox = null,

        /// Current suggestions
        current_suggestions: std.ArrayList(PromptSuggestion),

        pub var offset: c_int = 0;
    };

    /// Thread context for AI requests
    const AiThreadContext = struct {
        input_mode: *AiInputMode,
        config_ref: *Config,
        prompt: []const u8,
        context: ?[]const u8,
        assistant: AiAssistant,
        enable_streaming: bool,
    };

    /// Result from AI request
    const AiResult = struct {
        input_mode: *AiInputMode,
        response: ?[:0]const u8,
        err: ?[:0]const u8,
        is_final: bool,
    };

    /// Streaming chunk for incremental UI updates
    const StreamChunk = struct {
        input_mode: *AiInputMode,
        content: []const u8,
        done: bool,
    };

    /// Global streaming state (accessed only from background thread)
    var streaming_state_mutex = std.Thread.Mutex{};
    var streaming_state: ?*AiInputMode = null;

    /// Built-in prompt templates
    const PromptTemplate = struct {
        name: [:0]const u8,
        template: []const u8,
        description: [:0]const u8,
    };

    const prompt_templates: []const PromptTemplate = &.{
        .{
            .name = "Custom Question",
            .template = "{prompt}",
            .description = "Ask a custom question",
        },
        .{
            .name = "Explain",
            .template = "Explain this command/output in simple terms:\n\n{selection}",
            .description = "Explain the selected command or output",
        },
        .{
            .name = "Fix",
            .template = "What's wrong with this command and how do I fix it?\n\n{selection}",
            .description = "Identify and fix issues",
        },
        .{
            .name = "Optimize",
            .template = "Optimize this command for better performance:\n\n{selection}",
            .description = "Suggest optimizations",
        },
        .{
            .name = "Rewrite",
            .template = "Rewrite this command using modern best practices:\n\n{selection}",
            .description = "Modernize the command",
        },
        .{
            .name = "Debug",
            .template = "Help debug this error:\n\n{selection}\n\nTerminal context:\n{context}",
            .description = "Debug with context",
        },
        .{
            .name = "Complete",
            .template = "Complete this command based on the pattern:\n\n{selection}",
            .description = "Auto-complete",
        },
    };

    /// Create a new AI input mode instance
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});
        _ = self.refSink();
        return self.ref();
    }

    fn init(self: *Self) callconv(.C) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();
        priv.* = .{
            .current_suggestions = std.ArrayList(PromptSuggestion).init(alloc),
        };

        // Bind the template
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Initialize prompt suggestion service
        priv.prompt_suggestion_service = PromptSuggestionService.init(alloc, 5);

        // Populate the template dropdown
        const template_names = blk: {
            var names = std.ArrayList([:0]const u8).init(alloc);
            errdefer {
                for (names.items) |n| alloc.free(n);
                names.deinit();
            }
            for (prompt_templates) |t| {
                names.append(alloc.dupeZ(u8, t.name) catch continue) catch continue;
            }
            break :blk names.toOwnedSlice() catch &[_][:0]const u8{};
        };

        const string_list = ext.StringList.create(alloc, template_names) catch |err| {
            log.err("Failed to create template string list: {}", .{err});
            return;
        };
        priv.template_dropdown.setModel(string_list.as(gio.ListModel));

        // Set up action group for copy and execute functionality
        const action_group = gio.SimpleActionGroup.new();

        // Create copy-response action
        const copy_action = gio.SimpleAction.new("copy-response", null);
        _ = copy_action.connectActivate(*Self, copyResponseActivated, self, .{});
        action_group.addAction(copy_action.as(gio.Action));

        // Create execute-command action
        const execute_action = gio.SimpleAction.new("execute-command", null);
        _ = execute_action.connectActivate(*Self, executeCommandActivated, self, .{});
        action_group.addAction(execute_action.as(gio.Action));

        // Insert action group into widget
        self.as(gtk.Widget).insertActionGroup("ai", action_group.as(gio.ActionGroup));

        // TODO: Prompt suggestions feature (incomplete)
        // TODO: Connect to text buffer changes for prompt suggestions
        // _ = priv.input_buffer.connectChanged(*Self, inputBufferChanged, self, .{});
        // TODO: Create suggestion popup
        // priv.suggestion_popup = gtk.Popover.new(priv.input_view.as(gtk.Widget));
        // priv.suggestion_popup.?.setPosition(gtk.PositionType.top);
        // TODO: Create suggestion list
        // priv.suggestion_list = gtk.ListBox.new();
        // priv.suggestion_list.?.setSelectionMode(gtk.SelectionMode.single);
        // _ = priv.suggestion_list.?.connectRowActivated(*Self, suggestionRowActivated, self, .{});
        // TODO: Add list to popup
        // const scrolled = gtk.ScrolledWindow.new(null, null);
        // scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
        // scrolled.setMaxContentHeight(200);
        // scrolled.setChild(priv.suggestion_list.?.as(gtk.Widget));
        // priv.suggestion_popup.?.setChild(scrolled.as(gtk.Widget));
    }

    fn agent_toggled(button: *gtk.ToggleButton, self: *Self) callconv(.C) void {
        const priv = getPriv(self);
        priv.agent_mode = button.getActive() != 0;
    }

    /// Action handler for copying the selected response to clipboard
    fn copyResponseActivated(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.C) void {
        _ = action;
        _ = param;

        const priv = getPriv(self);

        // Get the selected response from the list
        const model = priv.response_view.getModel() orelse return;
        const selection = model.as(gtk.SingleSelection);
        const selected = selection.getSelected();

        const item = priv.response_store.getItem(selected) orelse return;
        const response_item: *ResponseItem = @ptrCast(@alignCast(item));

        // Get the response private data
        const item_priv = gobject.ext.getPriv(response_item, &ResponseItem.ResponseItemPrivate.offset);
        const content = item_priv.content;

        // Strip Pango markup to get plain text
        const alloc = Application.default().allocator();
        const plain_text = stripPangoMarkup(alloc, content) catch content;
        defer if (plain_text.ptr != content.ptr) alloc.free(plain_text);

        // Copy to clipboard
        const clipboard = priv.dialog.as(gtk.Widget).getClipboard();
        clipboard.setText(plain_text);

        log.info("Copied AI response to clipboard", .{});
    }

    /// Action handler for executing command from AI response
    fn executeCommandActivated(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.C) void {
        _ = action;
        _ = param;

        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Get the window reference
        const win = priv.window orelse {
            log.err("No window reference available for command execution", .{});
            return;
        };

        // Get the selected response from the list
        const model = priv.response_view.getModel() orelse return;
        const selection = model.as(gtk.SingleSelection);
        const selected = selection.getSelected();

        const item = priv.response_store.getItem(selected) orelse return;
        const response_item: *ResponseItem = @ptrCast(@alignCast(item));

        // Get the response private data
        const item_priv = gobject.ext.getPriv(response_item, &ResponseItem.ResponseItemPrivate.offset);
        const content = item_priv.content;
        const item_command = item_priv.command;

        // Strip Pango markup to get plain text
        const plain_text = stripPangoMarkup(alloc, content) catch content;
        defer if (plain_text.ptr != content.ptr) alloc.free(plain_text);

        const command = if (item_command.len > 0)
            item_command
        else
            extractCommand(alloc, plain_text) catch {
                log.err("Failed to extract command from response", .{});
                return;
            };
        defer if (item_command.len == 0 and command.ptr != plain_text.ptr) alloc.free(command);

        if (command.len == 0) {
            log.warn("No command found in response to execute", .{});
            return;
        }

        log.info("Executing command: {s}", .{command});

        // Get the active surface from the window
        const surface = win.getActiveSurface() orelse {
            log.err("No active surface available", .{});
            return;
        };

        const core_surface = surface.core() orelse {
            log.err("No core surface available", .{});
            return;
        };

        // Append newline to execute the command
        const command_with_newline = alloc.alloc(u8, command.len + 1) catch {
            log.err("Failed to allocate command buffer", .{});
            return;
        };
        defer alloc.free(command_with_newline);
        @memcpy(command_with_newline[0..command.len], command);
        command_with_newline[command.len] = '\n';

        // Execute the command by sending text to the terminal
        _ = core_surface.performBindingAction(.{ .text = command_with_newline }) catch |err| {
            log.err("Failed to execute command: {}", .{err});
            return;
        };

        // Close the dialog after executing
        priv.dialog.forceClose();
    }

    /// Extract command from AI response text
    /// Looks for code blocks (``` or `code`) or uses first non-empty line
    fn extractCommand(alloc: Allocator, text: [:0]const u8) ![:0]const u8 {
        // Look for triple backtick code blocks
        if (std.mem.indexOf(u8, text, "```")) |start| {
            const code_start = start + 3;
            // Skip language identifier on same line (e.g., ```bash)
            var actual_start = code_start;
            while (actual_start < text.len and text[actual_start] != '\n') {
                actual_start += 1;
            }
            if (actual_start < text.len) actual_start += 1; // Skip newline

            if (std.mem.indexOfPos(u8, text, actual_start, "```")) |end| {
                const code = std.mem.trim(u8, text[actual_start..end], " \t\n\r");
                if (code.len > 0) {
                    return try alloc.dupeZ(u8, code);
                }
            }
        }

        // Look for inline code blocks (`code`)
        if (std.mem.indexOf(u8, text, "`")) |start| {
            const code_start = start + 1;
            if (std.mem.indexOfPos(u8, text, code_start, "`")) |end| {
                const code = std.mem.trim(u8, text[code_start..end], " \t\n\r");
                if (code.len > 0) {
                    return try alloc.dupeZ(u8, code);
                }
            }
        }

        // Fall back to first non-empty line
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) {
                return try alloc.dupeZ(u8, trimmed);
            }
        }

        return text;
    }

    /// Strip Pango markup to get plain text
    fn stripPangoMarkup(alloc: Allocator, input: [:0]const u8) ![:0]const u8 {
        var result = std.ArrayList(u8).init(alloc);
        errdefer result.deinit();

        var i: usize = 0;
        while (i < input.len) {
            // Skip XML tags
            if (input[i] == '<') {
                // Find closing >
                while (i < input.len and input[i] != '>') {
                    i += 1;
                }
                if (i < input.len) i += 1;
                continue;
            }

            // Unescape HTML entities
            if (input[i] == '&') {
                if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "&lt;")) {
                    try result.append('<');
                    i += 4;
                    continue;
                } else if (i + 4 <= input.len and std.mem.eql(u8, input[i .. i + 4], "&gt;")) {
                    try result.append('>');
                    i += 4;
                    continue;
                } else if (i + 5 <= input.len and std.mem.eql(u8, input[i .. i + 5], "&amp;")) {
                    try result.append('&');
                    i += 5;
                    continue;
                }
            }

            try result.append(input[i]);
            i += 1;
        }

        return result.toOwnedSliceSentinel(0);
    }

    /// Extract command from code blocks in markdown content
    /// Returns the first code block content that looks like a shell command
    fn extractCommandFromMarkdown(alloc: Allocator, input: [:0]const u8) ![:0]const u8 {
        var commands = extractCommandsFromMarkdown(alloc, input) catch return "";
        defer commands.deinit();

        if (commands.items.len == 0) return "";

        const first = commands.items[0];
        for (commands.items[1..]) |cmd| alloc.free(cmd);
        return first;
    }

    fn extractCommandsFromMarkdown(
        alloc: Allocator,
        input: [:0]const u8,
    ) !std.ArrayList([:0]const u8) {
        var commands = std.ArrayList([:0]const u8).init(alloc);
        errdefer {
            for (commands.items) |cmd| alloc.free(cmd);
            commands.deinit();
        }

        const input_len = input.len;
        var i: usize = 0;

        while (i + 2 < input_len) {
            if (std.mem.eql(u8, input[i .. i + 3], "```")) {
                var start = i + 3;
                while (start < input_len and input[start] != '\n') {
                    start += 1;
                }
                if (start < input_len) start += 1;

                const end_idx = std.mem.indexOfPos(u8, input, start, "```") orelse input_len;
                const block = input[start..end_idx];

                var lines = std.mem.splitScalar(u8, block, '\n');
                while (lines.next()) |line| {
                    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
                    if (trimmed.len == 0) continue;
                    if (trimmed[0] == '#') continue;
                    try commands.append(try alloc.dupeZ(u8, trimmed));
                }

                i = end_idx + 3;
                continue;
            }

            i += 1;
        }

        if (commands.items.len > 0) return commands;

        i = 0;
        while (i < input_len) {
            if (input[i] == '`') {
                const end_idx = std.mem.indexOfPos(u8, input, i + 1, "`") orelse {
                    i += 1;
                    continue;
                };
                const code = input[i + 1 .. end_idx];
                const trimmed = std.mem.trim(u8, code, &std.ascii.whitespace);
                if (trimmed.len > 0) {
                    try commands.append(try alloc.dupeZ(u8, trimmed));
                }
                i = end_idx + 1;
                continue;
            }
            i += 1;
        }

        return commands;
    }

    pub const Class = struct {
        parent: Parent.Class,

        pub fn init(
            klass: *gobject.Class.Type,
            _: ?*anyopaque,
        ) callconv(.C) void {
            klass.parent = gobject.ext.initClass(Parent, .{
                .name = "GhosttyAiInputMode",
                .instance_size = @sizeOf(Self),
                .class_size = @sizeOf(Class),
            }).?;
        }
    };

    /// Show the AI input dialog
    pub fn show(self: *Self, win: *Window, selected_text: ?[]const u8, terminal_context: ?[]const u8) void {
        const priv = getPriv(self);
        priv.selected_text = selected_text;
        priv.terminal_context = terminal_context;
        priv.window = win;

        // Update context label if we have selection
        if (selected_text != null) {
            priv.context_label.setVisible(true);
        } else {
            priv.context_label.setVisible(false);
        }

        // Update context chips to show available context
        self.updateContextChips();

        // Present the dialog
        priv.dialog.present(win.as(gtk.Widget));
    }

    /// Update context chips based on available context
    fn updateContextChips(self: *Self) void {
        const priv = getPriv(self);

        // Show selection chip if we have selected text
        priv.selection_chip.setVisible(priv.selected_text != null);

        // Show history chip if we have terminal context
        priv.history_chip.setVisible(priv.terminal_context != null);

        // Update directory chip with current working directory
        const alloc = Application.default().allocator();
        const cwd = std.fs.cwd().realpathAlloc(alloc, ".") catch {
            priv.directory_chip.setVisible(false);
            priv.git_chip.setVisible(false);
            priv.context_chips.setVisible(priv.selection_chip.getVisible() or priv.history_chip.getVisible());
            return;
        };
        defer alloc.free(cwd);

        // Abbreviate home directory
        const home = std.posix.getenv("HOME") orelse "";
        var path_buf: [256]u8 = undefined;
        const display_path: [:0]const u8 = if (std.mem.startsWith(u8, cwd, home)) blk: {
            const tail = cwd[home.len..];
            const formatted = std.fmt.bufPrintZ(&path_buf, "~{s}", .{tail}) catch "~/";
            break :blk formatted;
        } else std.fmt.bufPrintZ(&path_buf, "{s}", .{cwd}) catch "~/";

        priv.directory_label.setLabel(display_path);
        priv.directory_chip.setVisible(true);

        // Check for git branch
        if (detectGitBranch(alloc)) |branch| {
            priv.git_label.setLabel(branch);
            priv.git_chip.setVisible(true);
            alloc.free(branch);
        } else |_| {
            priv.git_chip.setVisible(false);
        }

        // Show the chips container if any chip is visible
        const any_visible = priv.selection_chip.getVisible() or
            priv.history_chip.getVisible() or
            priv.directory_chip.getVisible() or
            priv.git_chip.getVisible();
        priv.context_chips.setVisible(any_visible);
    }

    /// Detect git branch if in a git repository
    fn detectGitBranch(alloc: Allocator) ![:0]const u8 {
        // Read .git/HEAD
        const git_head = std.fs.cwd().openFile(".git/HEAD", .{}) catch return error.NotAGitRepo;
        defer git_head.close();

        var buf: [256]u8 = undefined;
        const bytes_read = git_head.read(&buf) catch return error.ReadError;
        if (bytes_read == 0) return error.EmptyFile;

        const content = buf[0..bytes_read];

        // Parse "ref: refs/heads/branch-name"
        if (std.mem.startsWith(u8, content, "ref: refs/heads/")) {
            const branch_start = "ref: refs/heads/".len;
            const branch_end = std.mem.indexOf(u8, content[branch_start..], "\n") orelse (bytes_read - branch_start);
            return alloc.dupeZ(u8, content[branch_start .. branch_start + branch_end]) catch return error.AllocError;
        }

        // Detached HEAD - return short commit hash
        const hash_end = std.mem.indexOf(u8, content, "\n") orelse bytes_read;
        const hash = content[0..@min(hash_end, 7)];
        return alloc.dupeZ(u8, hash) catch return error.AllocError;
    }

    /// Set the configuration for this AI input mode
    pub fn setConfig(self: *Self, config: *Config) void {
        const priv = getPriv(self);
        priv.config = config;
        const cfg = config.get();

        // Initialize assistant
        if (cfg.@"ai-enabled") {
            const provider_enum: ?AiAssistant.Provider = if (cfg.@"ai-provider") |p| switch (p) {
                .openai => .openai,
                .anthropic => .anthropic,
                .ollama => .ollama,
                .custom => .custom,
            } else null;

            if (provider_enum) |p| {
                const ai_config = AiAssistant.Config{
                    .enabled = cfg.@"ai-enabled",
                    .provider = p,
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
                if (AiAssistant.init(alloc, ai_config)) |assistant| {
                    priv.assistant = assistant;
                } else |_| {
                    priv.assistant = null;
                }
            } else {
                priv.assistant = null;
            }
        } else {
            priv.assistant = null;
        }

        // Update send button sensitivity based on AI config
        const enabled = cfg.@"ai-enabled";
        const provider = cfg.@"ai-provider" != null;
        const api_key = cfg.@"ai-api-key".len > 0 or
            (cfg.@"ai-provider" != null and cfg.@"ai-provider".? == .ollama);

        priv.send_sensitive = enabled and provider and api_key;
        self.notify(properties.send_sensitive.name);
    }

    /// Signal handler for dialog close
    fn closed(dialog: *adw.Dialog, self: *Self) callconv(.C) void {
        const priv = getPriv(self);

        // Clear the response store
        const n_items: c_uint = @intCast(priv.response_store.nItems());
        if (n_items > 0) {
            priv.response_store.remove(0, n_items);
        }

        // Clear the input buffer
        priv.input_buffer.setText("", -1);

        // Hide the dialog
        dialog.forceClose();
    }

    /// Redact sensitive information from text before sharing
    fn redactSensitiveData(alloc: Allocator, text: [:0]const u8) ![:0]const u8 {
        // For now, do simple string-based redaction
        // TODO: Implement proper regex-based redaction

        var result = try alloc.dupe(u8, text);
        errdefer alloc.free(result);

        // Common patterns to redact
        const patterns = [_]struct {
            prefix: []const u8,
            min_length: usize,
            replacement: []const u8,
        }{
            .{ .prefix = "sk-", .min_length = 20, .replacement = "[REDACTED_API_KEY]" },
            .{ .prefix = "AKIA", .min_length = 20, .replacement = "[REDACTED_AWS_KEY]" },
            .{ .prefix = "ghp_", .min_length = 36, .replacement = "[REDACTED_GITHUB_TOKEN]" },
            .{ .prefix = "password=", .min_length = 8, .replacement = "password=[REDACTED]" },
            .{ .prefix = "token=", .min_length = 16, .replacement = "token=[REDACTED]" },
            .{ .prefix = "secret=", .min_length = 16, .replacement = "secret=[REDACTED]" },
        };

        // Apply redactions
        for (patterns) |pattern| {
            if (std.mem.indexOf(u8, result, pattern.prefix)) |idx| {
                var end = idx + pattern.prefix.len;
                while (end < result.len and
                       (std.ascii.isAlphanumeric(result[end]) or
                        result[end] == '-' or
                        result[end] == '_' or
                        result[end] == '!' or
                        result[end] == '@' or
                        result[end] == '#' or
                        result[end] == '$' or
                        result[end] == '%' or
                        result[end] == '^' or
                        result[end] == '&' or
                        result[end] == '*' or
                        result[end] == '(' or
                        result[end] == ')' or
                        result[end] == '+' or
                        result[end] == '=')) {
                    end += 1;
                }

                // Only redact if it's long enough to be a real secret
                if (end - idx >= pattern.min_length) {
                    const before = result[0..idx];
                    const after = result[end..];
                    const redacted = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ before, pattern.replacement, after });
                    alloc.free(result);
                    result = redacted;
                }
            }
        }

        return result;
    }

    /// Signal handler for send button click
    fn send_clicked(button: *gtk.Button, self: *Self) callconv(.C) void {
        _ = button;
        const priv = getPriv(self);
        const config = priv.config orelse return;

        // Check if AI is properly configured
        if (!priv.send_sensitive) return;
        if (priv.assistant == null) {
            _ = self.addResponse("Error: AI Assistant not initialized. Please check your configuration and logs.") catch {};
            return;
        }

        // Get the input text
        const alloc = Application.default().allocator();

        // Get template and selected text
        const template_idx = priv.template_dropdown.getSelected();
        const template = if (template_idx >= 0 and template_idx < prompt_templates.len)
            prompt_templates[@intCast(template_idx)]
        else
            prompt_templates[0]; // Default to custom

        // Get the user's input from the text view
        const input_text = blk: {
            const start: gtk.TextIter = undefined;
            const end: gtk.TextIter = undefined;
            priv.input_buffer.getBounds(&start, &end);
            break :blk priv.input_buffer.getText(&start, &end, false);
        };

        // Build the final prompt
        const selection = priv.selected_text orelse "";
        const context = priv.terminal_context orelse "";

        const prompt = blk: {
            // Get the template content
            const template_str = template.template;

            // For custom template, just use input
            if (template_idx == 0) {
                // Custom question - just use input
                break :blk input_text;
            }

            // Otherwise, build prompt from template
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();

            var i: usize = 0;
            while (i < template_str.len) {
                if (i + 11 <= template_str.len and std.mem.eql(u8, template_str[i .. i + 11], "{selection}")) {
                    try buf.writer().writeAll(selection);
                    i += 11;
                } else if (i + 9 <= template_str.len and std.mem.eql(u8, template_str[i .. i + 9], "{context}")) {
                    try buf.writer().writeAll(context);
                    i += 9;
                } else if (i + 9 <= template_str.len and std.mem.eql(u8, template_str[i .. i + 9], "{prompt}")) {
                    try buf.writer().writeAll(input_text);
                    i += 9;
                } else {
                    try buf.writer().writeByte(template_str[i]);
                    i += 1;
                }
            }

            break :blk buf.toOwnedSlice() catch "";
        };
        const agent_prompt_suffix = "\n\nIf you provide commands, wrap them in fenced code blocks and put one command per line.";
        const prompt_final = blk: {
            if (!priv.agent_mode) break :blk prompt;
            var buf: std.Io.Writer.Allocating = .init(alloc);
            defer buf.deinit();
            buf.writer().writeAll(prompt) catch break :blk prompt;
            buf.writer().writeAll(agent_prompt_suffix) catch break :blk prompt;
            break :blk buf.toOwnedSlice() catch prompt;
        };
        defer if (prompt_final.ptr != prompt.ptr) alloc.free(prompt_final);

        // Show loading state
        priv.response_view.setVisible(false);
        priv.loading_label.setVisible(true);

        // Update button states
        priv.send_sensitive = false;
        priv.stop_sensitive = true;
        priv.regenerate_sensitive = false;
        self.notify(properties.send_sensitive.name);
        self.notify(properties.stop_sensitive.name);
        self.notify(properties.regenerate_sensitive.name);

        // Reset cancellation flag
        priv.request_cancelled = false;

        // Save prompt and context for regeneration
        if (priv.last_prompt) |old| alloc.free(old);
        if (priv.last_context) |old| alloc.free(old);
        priv.last_prompt = alloc.dupe(u8, prompt_final) catch {};
        priv.last_context = if (context.len > 0) alloc.dupe(u8, context) catch null else null;

        // Prepare thread context
        const prompt_dupe = alloc.dupe(u8, prompt_final) catch return;
        const context_dupe = if (context.len > 0) alloc.dupe(u8, context) catch null else null;

        // Ref config to keep it alive for the thread
        _ = config.ref();

        // Enable streaming for all providers (config option can disable it)
        const enable_streaming = config.get().@"ai-enabled";

        const ctx = AiThreadContext{
            .input_mode = self,
            .config_ref = config,
            .prompt = prompt_dupe,
            .context = context_dupe,
            .assistant = priv.assistant.?,
            .enable_streaming = enable_streaming,
        };

        // Ref the widget to keep it alive
        _ = self.ref();

        const thread = std.Thread.spawn(.{}, aiThreadMain, .{ctx}) catch |err| {
            log.err("Failed to spawn thread: {}", .{err});
            alloc.free(prompt_dupe);
            if (context_dupe) |c| alloc.free(c);
            config.unref();
            self.unref();
            priv.loading_label.setVisible(false);
            priv.response_view.setVisible(true);
            priv.send_sensitive = true;
            self.notify(properties.send_sensitive.name);
            return;
        };
        thread.detach();
    }

    fn aiThreadMain(ctx: AiThreadContext) void {
        const alloc = Application.default().allocator();
        defer alloc.free(ctx.prompt);
        defer if (ctx.context) |c| alloc.free(c);
        defer ctx.config_ref.unref();

        var assistant = ctx.assistant;

        // Use streaming if enabled
        if (ctx.enable_streaming) {
            // Initialize streaming state
            {
                streaming_state_mutex.lock();
                streaming_state = ctx.input_mode;
                streaming_state_mutex.unlock();
            }
            defer {
                streaming_state_mutex.lock();
                streaming_state = null;
                streaming_state_mutex.unlock();
            }

            // Initialize streaming on main thread
            const stream_init = alloc.create(StreamChunk) catch return;
            stream_init.* = .{
                .input_mode = ctx.input_mode,
                .content = "",
                .done = false,
            };
            _ = glib.idleAdd(streamInitCallback, stream_init);

            // Create callback with closure using global state
            const callback = struct {
                fn inner(chunk: ai_client.StreamChunk) void {
                    streaming_state_mutex.lock();
                    const input_mode = streaming_state;
                    streaming_state_mutex.unlock();

                    if (input_mode) |mode| {
                        const alloc_cb = Application.default().allocator();
                        const stream_chunk = alloc_cb.create(StreamChunk) catch return;
                        stream_chunk.* = .{
                            .input_mode = mode,
                            .content = alloc_cb.dupe(u8, chunk.content) catch "",
                            .done = chunk.done,
                        };
                        _ = glib.idleAdd(streamChunkCallback, stream_chunk);
                    }
                }
            }.inner;

            // Create stream options
            const stream_options = ai_client.StreamOptions{
                .callback = callback,
                .enabled = true,
            };

            // Process with streaming (this blocks until stream completes)
            assistant.processStream(ctx.prompt, ctx.context, stream_options) catch |err| {
                // On error, send error result
                const ai_result = alloc.create(AiResult) catch return;
                ai_result.* = .{
                    .input_mode = ctx.input_mode,
                    .response = null,
                    .err = std.fmt.allocPrintZ(alloc, "Error: {s}", .{@errorName(err)}) catch null,
                    .is_final = true,
                };
                _ = glib.idleAdd(aiResultCallback, ai_result);
            };
        } else {
            // Use blocking API
            const result = assistant.process(ctx.prompt, ctx.context);

            const ai_result = alloc.create(AiResult) catch return;
            ai_result.* = .{
                .input_mode = ctx.input_mode,
                .response = null,
                .err = null,
                .is_final = true,
            };

            if (result) |res| {
                defer res.deinit(alloc);
                ai_result.response = alloc.dupeZ(u8, res.content) catch null;
            } else |err| {
                ai_result.err = std.fmt.allocPrintZ(alloc, "Error: {s}", .{@errorName(err)}) catch null;
            }

            _ = glib.idleAdd(aiResultCallback, ai_result);
        }
    }

    /// Callback to initialize streaming state on main thread
    fn streamInitCallback(data: ?*anyopaque) callconv(.C) c_int {
        const chunk: *StreamChunk = @ptrCast(@alignCast(data));
        const alloc = Application.default().allocator();
        defer alloc.destroy(chunk);

        const self = chunk.input_mode;
        const priv = getPriv(self);

        // Initialize streaming response buffer
        priv.streaming_response = std.ArrayList(u8).init(alloc);

        // Create initial empty response item with empty command
        const item = ResponseItem.new("", "");
        priv.response_store.append(item);

        // Keep reference to the response item for updates
        priv.streaming_response_item = item;

        // Show response view and hide loading
        priv.response_view.setVisible(true);
        priv.loading_label.setVisible(false);

        return 0; // G_SOURCE_REMOVE
    }

    /// Callback to handle streaming chunks on main thread
    fn streamChunkCallback(data: ?*anyopaque) callconv(.C) c_int {
        const chunk: *StreamChunk = @ptrCast(@alignCast(data));
        const alloc = Application.default().allocator();
        defer alloc.destroy(chunk);
        defer if (chunk.content.len > 0) alloc.free(chunk.content);

        const self = chunk.input_mode;
        const priv = getPriv(self);

        // If the user cancelled, ignore intermediate chunks but still handle the final "done" chunk.
        if (priv.request_cancelled and !chunk.done) return 0; // G_SOURCE_REMOVE

        if (priv.streaming_response) |*buffer| {
            // Append new content to buffer
            buffer.appendSlice(chunk.content) catch return 1;

            // Update the response item with new content
            if (priv.streaming_response_item) |item| {
                const item_priv = gobject.ext.getPriv(item, &ResponseItem.ResponseItemPrivate.offset);

                // Convert accumulated content to sentinel-terminated string for markup
                const content_z_for_markup = alloc.dupeZ(u8, buffer.items) catch return 1;
                const markup = markup: {
                    if (markdownToPango(alloc, content_z_for_markup)) |m| {
                        alloc.free(content_z_for_markup);
                        break :markup m;
                    } else |_| {
                        // Keep `content_z_for_markup` as plain text fallback.
                        break :markup content_z_for_markup;
                    }
                };

                // Replace content (avoid freeing string literals)
                if (item_priv.content.len > 0) alloc.free(item_priv.content);
                item_priv.content = markup;

                // Trigger UI update by notifying the store
                priv.response_store.itemsChanged(@intCast(priv.response_store.nItems() - 1), 1, 1);
            }

            // If this is the final chunk, clean up streaming state
            if (chunk.done) {
                if (priv.streaming_response_item) |item| {
                    const item_priv = gobject.ext.getPriv(item, &ResponseItem.ResponseItemPrivate.offset);

                    // Convert accumulated content to sentinel-terminated string for command extraction
                    const content_z_for_command = alloc.dupeZ(u8, buffer.items) catch return 1;
                    defer alloc.free(content_z_for_command);

                    const command = extractCommandFromMarkdown(alloc, content_z_for_command) catch "";
                    if (item_priv.command.len == 0 and command.len > 0) {
                        item_priv.command = command;
                    } else if (command.len > 0) {
                        alloc.free(command);
                    }
                    // Clear the reference but don't free the item (store owns it)
                    priv.streaming_response_item = null;
                }
                priv.streaming_response = null;

                // Re-enable send button
                if (priv.config) |cfg| {
                    self.setConfig(cfg);
                }

                // Update stop/regenerate button state
                priv.stop_sensitive = false;
                priv.regenerate_sensitive = priv.last_prompt != null;
                self.notify(properties.stop_sensitive.name);
                self.notify(properties.regenerate_sensitive.name);

                // Convert accumulated content to sentinel-terminated string for auto-execute
                const content_z_for_auto_execute = alloc.dupeZ(u8, buffer.items) catch return 1;
                defer alloc.free(content_z_for_auto_execute);

                self.maybeAutoExecuteFromResponse(content_z_for_auto_execute);
            }
        }

        return 0; // G_SOURCE_REMOVE
    }

    fn aiResultCallback(data: ?*anyopaque) callconv(.C) c_int {
        const result: *AiResult = @ptrCast(@alignCast(data));
        const alloc = Application.default().allocator();
        defer alloc.destroy(result);
        defer if (result.response) |r| alloc.free(r);
        defer if (result.err) |e| alloc.free(e);

        const self = result.input_mode;
        defer self.unref();

        const priv = getPriv(self);
        priv.loading_label.setVisible(false);
        priv.response_view.setVisible(true);

        // Re-enable send button
        if (priv.config) |cfg| {
            self.setConfig(cfg);
        }

        // Always end the in-flight request state
        priv.stop_sensitive = false;
        priv.regenerate_sensitive = priv.last_prompt != null;
        self.notify(properties.stop_sensitive.name);
        self.notify(properties.regenerate_sensitive.name);

        // If the user cancelled, ignore late-arriving results.
        if (priv.request_cancelled) return 0; // G_SOURCE_REMOVE

        if (result.response) |resp| {
            _ = self.addResponse(resp) catch {};
            self.maybeAutoExecuteFromResponse(resp);
        } else if (result.err) |err_msg| {
            _ = self.addResponse(err_msg) catch {};
        }

        return 0; // G_SOURCE_REMOVE
    }

    /// Signal handler for template dropdown change
    fn template_changed(dropdown: *gtk.DropDown, param: *gobject.ParamSpec, self: *Self) callconv(.C) void {
        _ = dropdown;
        _ = param;
        _ = self;
        // Template change handling can be added here if needed
        // For now, the template is applied when sending
    }

    /// Signal handler for stop button click
    fn stop_clicked(button: *gtk.Button, self: *Self) callconv(.C) void {
        _ = button;
        const priv = getPriv(self);

        // Set cancellation flag
        priv.request_cancelled = true;

        // Exit loading state immediately; any late result will be ignored.
        priv.loading_label.setVisible(false);
        priv.response_view.setVisible(true);

        // Re-enable send button (if config allows)
        if (priv.config) |cfg| {
            self.setConfig(cfg);
        }

        // Disable stop button
        priv.stop_sensitive = false;
        priv.regenerate_sensitive = priv.last_prompt != null;
        self.notify(properties.stop_sensitive.name);
        self.notify(properties.regenerate_sensitive.name);

        log.info("User requested to stop AI generation", .{});
    }

    /// Signal handler for regenerate button click
    fn regenerate_clicked(button: *gtk.Button, self: *Self) callconv(.C) void {
        _ = button;
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Check if we have a previous request to regenerate
        if (priv.last_prompt == null) {
            log.info("No previous prompt to regenerate", .{});
            return;
        }

        // Clear the last response
        const n_items: c_uint = @intCast(priv.response_store.nItems());
        if (n_items > 0) {
            priv.response_store.remove(0, n_items);
        }

        // Reset cancellation flag
        priv.request_cancelled = false;

        // Update button states
        priv.regenerate_sensitive = false;
        priv.send_sensitive = false;
        priv.stop_sensitive = true;
        self.notify(properties.regenerate_sensitive.name);
        self.notify(properties.send_sensitive.name);
        self.notify(properties.stop_sensitive.name);

        // Show loading state
        priv.response_view.setVisible(false);
        priv.loading_label.setVisible(true);

        // Prepare thread context with last prompt/context
        const prompt_dupe = alloc.dupe(u8, priv.last_prompt.?) catch return;
        const context_dupe = if (priv.last_context) |ctx|
            if (ctx.len > 0) alloc.dupe(u8, ctx) catch null else null
        else
            null;

        const config = priv.config orelse return;
        _ = config.ref();

        const enable_streaming = config.get().@"ai-enabled";

        const ctx = AiThreadContext{
            .input_mode = self,
            .config_ref = config,
            .prompt = prompt_dupe,
            .context = context_dupe,
            .assistant = priv.assistant.?,
            .enable_streaming = enable_streaming,
        };

        // Ref the widget to keep it alive
        _ = self.ref();

        const thread = std.Thread.spawn(.{}, aiThreadMain, .{ctx}) catch |err| {
            log.err("Failed to spawn thread: {}", .{err});
            alloc.free(prompt_dupe);
            if (context_dupe) |c| alloc.free(c);
            config.unref();
            self.unref();
            priv.loading_label.setVisible(false);
            priv.response_view.setVisible(true);
            priv.send_sensitive = true;
            self.notify(properties.send_sensitive.name);
            return;
        };
        thread.detach();

        log.info("Regenerating AI response", .{});
    }

    /// Add a response to the response list
    fn addResponse(self: *Self, content: [:0]const u8) !void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Apply redaction for sensitive data before processing
        const redacted_content = redactSensitiveData(alloc, content) catch content;
        const free_redacted = redacted_content.ptr != content.ptr;
        defer if (free_redacted) alloc.free(redacted_content);

        // Use redacted content for further processing
        const content_to_process = redacted_content;

        // Convert markdown to Pango markup
        const markup = markup: {
            if (markdownToPango(alloc, content_to_process)) |m| {
                break :markup m;
            } else |_| {
                if (alloc.dupeZ(u8, content_to_process)) |plain| {
                    break :markup plain;
                } else |_| {
                    // Fall back to storing the (redacted) plain text directly.
                    free_redacted = false;
                    break :markup content_to_process;
                }
            }
        };

        // Extract command from code blocks
        const command = extractCommandFromMarkdown(alloc, content_to_process) catch "";

        // Create a response item with markup and command
        const item = ResponseItem.new(markup, command);

        // Add to the store
        priv.response_store.append(item);

        // Show the response view and hide loading
        priv.response_view.setVisible(true);
        priv.loading_label.setVisible(false);
    }

    fn maybeAutoExecuteFromResponse(self: *Self, content: [:0]const u8) void {
        const priv = getPriv(self);
        if (!priv.agent_mode) return;

        const alloc = Application.default().allocator();

        const redacted_content = redactSensitiveData(alloc, content) catch content;
        defer if (redacted_content.ptr != content.ptr) alloc.free(redacted_content);

        var commands = extractCommandsFromMarkdown(alloc, redacted_content) catch return;
        defer {
            for (commands.items) |cmd| alloc.free(cmd);
            commands.deinit();
        }

        if (commands.items.len == 0) return;

        const win = priv.window orelse {
            log.err("No window reference available for agent mode execution", .{});
            return;
        };

        const surface = win.getActiveSurface() orelse {
            log.err("No active surface available for agent mode execution", .{});
            return;
        };

        const core_surface = surface.core() orelse {
            log.err("No core surface available for agent mode execution", .{});
            return;
        };

        for (commands.items) |cmd| {
            const command_with_newline = alloc.alloc(u8, cmd.len + 1) catch {
                log.err("Failed to allocate command buffer", .{});
                return;
            };
            defer alloc.free(command_with_newline);
            @memcpy(command_with_newline[0..cmd.len], cmd);
            command_with_newline[cmd.len] = '\n';

            _ = core_surface.performBindingAction(.{ .text = command_with_newline }) catch |err| {
                log.err("Failed to execute agent command: {}", .{err});
                return;
            };
        }
    }

    /// Convert markdown to Pango markup
    fn markdownToPango(alloc: Allocator, input: [:0]const u8) ![:0]const u8 {
        var result = std.ArrayList(u8).init(alloc);
        errdefer result.deinit();

        var i: usize = 0;
        const input_len = input.len;

        while (i < input_len) {
            // Code blocks: ```code```
            if (i + 6 < input_len and std.mem.eql(u8, input[i..i+3], "```")) {
                const end_idx = std.mem.indexOfPos(u8, input, i + 3, "```") orelse input_len;
                try result.append("<tt>");
                try result.appendSlice(input[i + 3 .. end_idx]);
                try result.append("</tt>\n");
                i = end_idx + 3;
                continue;
            }

            // Inline code: `code`
            if (input[i] == '`') {
                const end_idx = std.mem.indexOfPos(u8, input, i + 1, "`") orelse {
                    try result.appendByte(input[i]);
                    i += 1;
                    continue;
                };
                try result.append("<tt>");
                try result.appendSlice(input[i + 1 .. end_idx]);
                try result.append("</tt>");
                i = end_idx + 1;
                continue;
            }

            // Bold: **text** or __text__
            if ((i + 4 < input_len and std.mem.eql(u8, input[i..i+2], "**")) or
                (i + 4 < input_len and std.mem.eql(u8, input[i..i+2], "__"))) {
                const marker = input[i..i+2];
                const end_idx = std.mem.indexOfPos(u8, input, i + 2, marker) orelse {
                    try result.appendByte(input[i]);
                    i += 1;
                    continue;
                };
                try result.append("<b>");
                try result.appendSlice(input[i + 2 .. end_idx]);
                try result.append("</b>");
                i = end_idx + 2;
                continue;
            }

            // Italic: *text* or _text_
            if ((i + 3 < input_len and (input[i] == '*' or input[i] == '_')) and
                (input[i+1] != '*' and input[i+1] != '_')) {
                const marker = input[i..i+1];
                const end_idx = std.mem.indexOfPos(u8, input, i + 1, marker) orelse {
                    try result.appendByte(input[i]);
                    i += 1;
                    continue;
                };
                try result.append("<i>");
                try result.appendSlice(input[i + 1 .. end_idx]);
                try result.append("</i>");
                i = end_idx + 1;
                continue;
            }

            // Headers: # text
            if (input[i] == '#' and (i == 0 or input[i-1] == '\n')) {
                var count: usize = 0;
                while (i + count < input_len and input[i + count] == '#') count += 1;
                if (count <= 6 and i + count < input_len and input[i + count] == ' ') {
                    const header_start = i + count + 1;
                    const end_idx = std.mem.indexOfScalar(u8, input[header_start..], '\n') orelse input_len - header_start;
                    const sizes = [_][]const u8{"xx-large", "x-large", "large", "medium", "small", "x-small"};
                    const size = if (count - 1 < sizes.len) sizes[count - 1] else "medium";
                    try result.print("<span size=\"{s}\"><b>", .{size});
                    try result.appendSlice(input[header_start .. header_start + end_idx]);
                    try result.append("</b></span>\n");
                    i = header_start + end_idx + 1;
                    continue;
                }
            }

            // Escape special characters for Pango
            if (input[i] == '<') {
                try result.append("&lt;");
            } else if (input[i] == '>') {
                try result.append("&gt;");
            } else if (input[i] == '&') {
                try result.append("&amp;");
            } else {
                try result.appendByte(input[i]);
            }
            i += 1;
        }

        return result.toOwnedSliceSentinel(0);
    }

    /// Handle text buffer changes for prompt suggestions
    fn inputBufferChanged(buffer: *gtk.TextBuffer, self: *Self) callconv(.C) void {
        _ = buffer;
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Get current text
        const start: gtk.TextIter = undefined;
        const end: gtk.TextIter = undefined;
        priv.input_buffer.getBounds(&start, &end);
        const text = priv.input_buffer.getText(&start, &end, false);

        // Check if we should show suggestions
        if (priv.prompt_suggestion_service) |*service| {
            if (!service.shouldShowSuggestion(text, 2)) {
                self.hideSuggestions();
                return;
            }

            // Get suggestions
            const suggestions = service.getSuggestions(text, priv.selected_text, priv.terminal_context) catch |err| {
                log.err("Failed to get prompt suggestions: {}", .{err});
                return;
            };
            defer {
                for (suggestions.items) |*s| s.deinit(alloc);
                suggestions.deinit();
            }

            // Show suggestions if we have any
            if (suggestions.items.len > 0) {
                self.showSuggestions(suggestions.items);
            } else {
                self.hideSuggestions();
            }
        }
    }

    /// Show suggestion popup with list of suggestions
    fn showSuggestions(self: *Self, suggestions: []const PromptSuggestion) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Clear current suggestions
        priv.current_suggestions.clearRetainingCapacity();
        for (suggestions) |suggestion| {
            // Copy suggestion to storage
            const copied = PromptSuggestion{
                .completion = alloc.dupe(u8, suggestion.completion) catch continue,
                .description = alloc.dupe(u8, suggestion.description) catch continue,
                .kind = suggestion.kind,
                .confidence = suggestion.confidence,
            };
            priv.current_suggestions.append(copied) catch continue;
        }

        // Clear list
        if (priv.suggestion_list) |list| {
            var child = list.getFirstChild();
            while (child) |c| {
                const next = c.getNextSibling();
                list.remove(c);
                child = next;
            }

            // Add new suggestions
            for (priv.current_suggestions.items) |suggestion| {
                const row = gtk.ListBoxRow.new();
                const box = gtk.Box.new(gtk.Orientation.vertical, 4);
                const box_widget = box.as(gtk.Widget);
                box_widget.setMarginTop(6);
                box_widget.setMarginBottom(6);
                box_widget.setMarginStart(12);
                box_widget.setMarginEnd(12);

                // Completion text
                const completion_label = gtk.Label.new(suggestion.completion);
                completion_label.setXAlign(0);
                completion_label.setUseMarkup(false);
                completion_label.getStyleContext().addClass("heading");
                box.append(completion_label.as(gtk.Widget));

                // Description text
                const desc_label = gtk.Label.new(suggestion.description);
                desc_label.setXAlign(0);
                desc_label.setUseMarkup(false);
                desc_label.getStyleContext().addClass("dim-label");
                desc_label.getStyleContext().addClass("caption");
                box.append(desc_label.as(gtk.Widget));

                row.setChild(box.as(gtk.Widget));
                list.append(row.as(gtk.Widget));
            }

            // Show popup if hidden
            if (priv.suggestion_popup) |popup| {
                if (!popup.getVisible()) {
                    popup.popup();
                }
            }
        }
    }

    /// Hide suggestion popup
    fn hideSuggestions(self: *Self) void {
        const priv = getPriv(self);

        // Clear current suggestions
        for (priv.current_suggestions.items) |*suggestion| {
            suggestion.deinit(Application.default().allocator());
        }
        priv.current_suggestions.clearRetainingCapacity();

        // Hide popup
        if (priv.suggestion_popup) |popup| {
            popup.popdown();
        }
    }

    /// Handle suggestion selection
    fn suggestionRowActivated(list: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.C) void {
        _ = list;
        const priv = getPriv(self);

        // Get selected index
        const index = row.getIndex();
        if (index < 0 or index >= @as(c_int, @intCast(priv.current_suggestions.items.len))) return;

        const suggestion = priv.current_suggestions.items[@intCast(index)];

        // Insert suggestion into input buffer
        const start: gtk.TextIter = undefined;
        const end: gtk.TextIter = undefined;
        priv.input_buffer.getBounds(&start, &end);
        priv.input_buffer.delete(&start, &end);
        priv.input_buffer.insert(&start, suggestion.completion, -1);

        // Hide suggestions
        self.hideSuggestions();

        log.info("Applied prompt suggestion: {}", .{suggestion.completion});
    }
};
