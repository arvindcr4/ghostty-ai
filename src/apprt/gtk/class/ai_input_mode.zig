const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;

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
const KnowledgeRulesManager = @import("../../../ai/main.zig").KnowledgeRulesManager;
const CommandPalette = @import("ai_command_palette.zig").CommandPalette;
const ChatHistorySidebar = @import("ai_chat_history.zig").ChatHistorySidebar;
const AiSettingsDialog = @import("ai_settings_dialog.zig").AiSettingsDialog;
const KeyboardShortcutsDialog = @import("ai_keyboard_shortcuts.zig").KeyboardShortcutsDialog;
const ExportImportDialog = @import("ai_export_import.zig").ExportImportDialog;
const NotificationCenter = @import("ai_notification_center.zig").NotificationCenter;
const InlineSuggestions = @import("ai_inline_suggestions.zig").InlineSuggestions;
const ThemeCustomizationDialog = @import("ai_theme_customization.zig").ThemeCustomizationDialog;
const SessionSharingDialog = @import("ai_session_sharing.zig").SessionSharingDialog;
const CommandAnalysisDialog = @import("ai_command_analysis.zig").CommandAnalysisDialog;

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

        fn responseItemInit(self: *@This()) callconv(.c) void {
            const priv = gobject.ext.getPriv(self, &ResponseItemPrivate.offset);
            priv.* = .{};
            self.content = "";
        }

        pub const ResponseItemClass = struct {
            parent: ResponseItemParent.Class,

            pub fn init(
                klass: *gobject.Class.Type,
                _: ?*anyopaque,
            ) callconv(.c) void {
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
            self.content = content.ptr;
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

        /// Provider dropdown for selecting AI provider
        provider_dropdown: *gtk.DropDown,

        /// Model dropdown for selecting AI models
        model_dropdown: *gtk.DropDown,

        /// API key entry field
        api_key_entry: *gtk.Entry,

        /// API key visibility toggle button
        api_key_toggle: *gtk.Button,

        /// Endpoint entry field (for custom provider)
        endpoint_entry: *gtk.Entry,

        /// Endpoint row container
        endpoint_row: *gtk.Box,

        /// Menu button for additional options
        menu_btn: *gtk.MenuButton,

        /// Progress bar for long operations
        progress_bar: ?*gtk.ProgressBar = null,

        /// Flag to prevent recursive updates
        updating_provider_dropdown: bool = false,
        updating_api_key: bool = false,

        /// Agent mode toggle
        agent_toggle: *gtk.ToggleButton,

        /// Voice input button
        voice_btn: *gtk.ToggleButton,

        /// Text view for user input
        input_view: *gtk.TextView,

        /// Text buffer for input
        input_buffer: *gtk.TextBuffer,

        /// Response list view
        response_view: *gtk.ListView,

        /// Response store
        response_store: *gio.ListStore,

        /// Chat history store
        chat_history_store: ?*gio.ListStore = null,

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

        /// Guard to prevent recursion when programmatically updating the model dropdown.
        updating_model_dropdown: bool = false,

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
        streaming_response: ?std.array_list.Managed(u8) = null,

        /// Current streaming response item (for incremental updates)
        streaming_response_item: ?*ResponseItem = null,

        /// Reference to the window for command execution
        window: ?*Window = null,

        /// Prompt suggestion service
        prompt_suggestion_service: ?PromptSuggestionService = null,

        /// Knowledge rules manager
        knowledge_rules: ?KnowledgeRulesManager = null,

        /// Suggestion popup window
        suggestion_popup: ?*gtk.Popover = null,

        /// Suggestion list box
        suggestion_list: ?*gtk.ListBox = null,

        /// Current suggestions
        current_suggestions: std.array_list.Managed(PromptSuggestion),

        /// Chat history sidebar
        history_sidebar: ?*ChatHistorySidebar = null,
        notification_center: ?*NotificationCenter = null,
        export_import_dialog: ?*ExportImportDialog = null,
        inline_suggestions: ?*InlineSuggestions = null,
        theme_customization_dialog: ?*ThemeCustomizationDialog = null,
        session_sharing_dialog: ?*SessionSharingDialog = null,
        command_analysis_dialog: ?*CommandAnalysisDialog = null,

        /// Flag to track if object has been disposed (prevents use-after-free)
        is_disposed: bool = false,

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

    /// Safely read the current streaming state with mutex protection
    fn getStreamingState() ?*AiInputMode {
        streaming_state_mutex.lock();
        defer streaming_state_mutex.unlock();
        return streaming_state;
    }

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

    fn init(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();
        priv.* = .{
            .current_suggestions = std.array_list.Managed(PromptSuggestion).init(alloc),
        };

        // Bind the template
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // TextView doesn't have a named buffer in the template; capture it now.
        priv.input_buffer = priv.input_view.getBuffer();

        // Initialize prompt suggestion service
        priv.prompt_suggestion_service = PromptSuggestionService.init(alloc, 5);

        // Initialize knowledge rules manager
        priv.knowledge_rules = KnowledgeRulesManager.init(alloc) catch |err| {
            log.warn("Failed to initialize knowledge rules manager: {}", .{err});
            priv.knowledge_rules = null;
        };

        // Initialize provider dropdown
        self.updateProviderDropdown();

        // Initialize API key entry
        self.updateApiKeyEntry();

        // Initialize endpoint entry
        self.updateEndpointEntry();

        // Register actions for menu
        self.registerActions();

        // Populate the template dropdown
        const template_names = blk: {
            var names = std.array_list.Managed([:0]const u8).init(alloc);
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

        // Prompt suggestions while typing
        _ = gtk.TextBuffer.signals.changed.connect(priv.input_buffer, *Self, inputBufferChanged, self, .{});

        priv.suggestion_popup = gtk.Popover.new();
        priv.suggestion_popup.?.setAutohide(@intFromBool(true));
        priv.suggestion_popup.?.setHasArrow(@intFromBool(false));
        priv.suggestion_popup.?.setPosition(gtk.PositionType.top);
        priv.suggestion_popup.?.as(gtk.Widget).setParent(priv.input_view.as(gtk.Widget));

        priv.suggestion_list = gtk.ListBox.new();
        priv.suggestion_list.?.setSelectionMode(gtk.SelectionMode.single);
        priv.suggestion_list.?.setActivateOnSingleClick(@intFromBool(true));
        _ = gtk.ListBox.signals.row_activated.connect(priv.suggestion_list.?, *Self, suggestionRowActivated, self, .{});

        const scrolled = gtk.ScrolledWindow.new();
        scrolled.setPolicy(gtk.PolicyType.never, gtk.PolicyType.automatic);
        scrolled.setMaxContentHeight(200);
        scrolled.setChild(priv.suggestion_list.?.as(gtk.Widget));
        priv.suggestion_popup.?.setChild(scrolled.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Mark as disposed to prevent use-after-free in callbacks
        priv.is_disposed = true;

        self.hideSuggestions();

        for (priv.current_suggestions.items) |*suggestion| suggestion.deinit(alloc);
        priv.current_suggestions.deinit();

        if (priv.streaming_response) |*buf| {
            buf.deinit();
            priv.streaming_response = null;
        }
        priv.streaming_response_item = null;

        if (priv.last_prompt) |prompt| alloc.free(prompt);
        priv.last_prompt = null;

        if (priv.last_context) |ctx| alloc.free(ctx);
        priv.last_context = null;

        if (priv.selected_text) |text| alloc.free(text);
        priv.selected_text = null;

        if (priv.terminal_context) |ctx| alloc.free(ctx);
        priv.terminal_context = null;

        if (priv.knowledge_rules) |*kr| {
            kr.deinit();
        }
        priv.knowledge_rules = null;

        // Clean up history sidebar if created
        if (priv.history_sidebar) |sidebar| {
            sidebar.unref();
            priv.history_sidebar = null;
        }

        // Clean up notification center if created
        if (priv.notification_center) |center| {
            center.unref();
            priv.notification_center = null;
        }

        // Clean up export/import dialog if created
        if (priv.export_import_dialog) |dialog| {
            dialog.unref();
            priv.export_import_dialog = null;
        }

        // Clean up inline suggestions if created
        if (priv.inline_suggestions) |suggestions| {
            suggestions.unref();
            priv.inline_suggestions = null;
        }

        // Clean up theme customization dialog if created
        if (priv.theme_customization_dialog) |dialog| {
            dialog.unref();
            priv.theme_customization_dialog = null;
        }

        // Clean up session sharing dialog if created
        if (priv.session_sharing_dialog) |dialog| {
            dialog.unref();
            priv.session_sharing_dialog = null;
        }

        // Clean up command analysis dialog if created
        if (priv.command_analysis_dialog) |dialog| {
            dialog.unref();
            priv.command_analysis_dialog = null;
        }

        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn agent_toggled(button: *gtk.ToggleButton, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        priv.agent_mode = button.getActive() != 0;
    }

    /// Signal handler for voice button toggle
    /// Voice input requires platform-specific speech recognition APIs.
    /// macOS uses Apple's Speech framework; GTK port shows a message explaining
    /// this feature is macOS-only. Linux would require integrating a speech
    /// recognition backend (e.g., Vosk, Whisper, or cloud service).
    fn voice_toggled(button: *gtk.ToggleButton, self: *Self) callconv(.c) void {
        _ = self;

        if (button.getActive() != 0) {
            // Voice input is macOS-only (uses Apple Speech framework)
            // Immediately toggle off the button and show info message
            button.setActive(0);

            // Show an info message dialog with error handling
            const info_dialog = adw.MessageDialog.new(null, "Voice Input Unavailable",
                \\Voice input requires platform-specific speech recognition APIs.
                \\This feature is currently available on macOS only using Apple's Speech framework.
                \\
                \\For Linux support, a speech recognition backend would need to be integrated.
            );
            info_dialog.addResponse("ok", "OK");
            info_dialog.setDefaultResponse("ok");

            // Present dialog with error handling
            info_dialog.present() catch |err| {
                log.err("Failed to present voice input dialog: {}", .{err});
                // Dialog will be cleaned up by reference counting
            };

            log.info("Voice input is macOS-only; not available on Linux/GTK", .{});
        }
    }

    /// Action handler for copying the selected response to clipboard
    fn copyResponseActivated(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
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
    fn executeCommandActivated(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
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

        // Learn from command execution for knowledge rules
        if (priv.knowledge_rules) |*kr| {
            const cwd_result = std.fs.cwd().realpathAlloc(alloc, ".");
            const cwd = cwd_result catch ".";
            defer if (cwd_result) |c| alloc.free(c);

            var command_history = ArrayList([]const u8).init(alloc);
            defer {
                for (command_history.items) |_| {}
                command_history.deinit();
            }

            // Add current command to history
            command_history.append(command) catch {};

            const rule_context = KnowledgeRulesManager.RuleContext{
                .cwd = cwd,
                .last_command = command,
                .command_history = command_history,
                .last_output = null,
                .git_state = null,
                .env_vars = StringHashMap([]const u8).init(alloc),
            };
            defer rule_context.env_vars.deinit();

            kr.learnFromInteraction(rule_context, command) catch |err| {
                log.warn("Failed to learn from interaction: {}", .{err});
            };
        }

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
        var result = std.array_list.Managed(u8).init(alloc);
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
    ) !std.array_list.Managed([:0]const u8) {
        var commands = std.array_list.Managed([:0]const u8).init(alloc);
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

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(ResponseItem);

            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "ai-input-mode",
                }),
            );

            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("template_dropdown", .{});
            class.bindTemplateChildPrivate("provider_dropdown", .{});
            class.bindTemplateChildPrivate("model_dropdown", .{});
            class.bindTemplateChildPrivate("api_key_entry", .{});
            class.bindTemplateChildPrivate("api_key_toggle", .{});
            class.bindTemplateChildPrivate("endpoint_entry", .{});
            class.bindTemplateChildPrivate("endpoint_row", .{});
            class.bindTemplateChildPrivate("menu_btn", .{});
            class.bindTemplateChildPrivate("progress_bar", .{});
            class.bindTemplateChildPrivate("agent_toggle", .{});
            class.bindTemplateChildPrivate("voice_btn", .{});
            class.bindTemplateChildPrivate("input_view", .{});
            class.bindTemplateChildPrivate("response_view", .{});
            class.bindTemplateChildPrivate("response_store", .{});
            class.bindTemplateChildPrivate("loading_label", .{});
            class.bindTemplateChildPrivate("context_label", .{});
            class.bindTemplateChildPrivate("context_chips", .{});
            class.bindTemplateChildPrivate("selection_chip", .{});
            class.bindTemplateChildPrivate("history_chip", .{});
            class.bindTemplateChildPrivate("directory_chip", .{});
            class.bindTemplateChildPrivate("directory_label", .{});
            class.bindTemplateChildPrivate("git_chip", .{});
            class.bindTemplateChildPrivate("git_label", .{});

            class.bindTemplateCallback("closed", &closed);
            class.bindTemplateCallback("template_changed", &template_changed);
            class.bindTemplateCallback("provider_changed", &providerChanged);
            class.bindTemplateCallback("model_changed", &model_changed);
            class.bindTemplateCallback("api_key_changed", &apiKeyChanged);
            class.bindTemplateCallback("api_key_toggle_clicked", &apiKeyToggleClicked);
            class.bindTemplateCallback("endpoint_changed", &endpointChanged);
            class.bindTemplateCallback("agent_toggled", &agent_toggled);
            class.bindTemplateCallback("voice_toggled", &voice_toggled);
            class.bindTemplateCallback("send_clicked", &send_clicked);
            class.bindTemplateCallback("stop_clicked", &stop_clicked);
            class.bindTemplateCallback("regenerate_clicked", &regenerate_clicked);

            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.send_sensitive.impl,
                properties.stop_sensitive.impl,
                properties.regenerate_sensitive.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };

    /// Show command palette (Warp-like)
    pub fn showCommandPalette(self: *Self) void {
        const priv = getPriv(self);
        const win = priv.window orelse return;

        const palette = CommandPalette.new();
        palette.show(win);
    }

    /// Toggle chat history sidebar
    pub fn toggleHistorySidebar(self: *Self) void {
        const priv = getPriv(self);
        // Check if disposed to prevent use-after-free
        if (priv.is_disposed) return;
        if (priv.history_sidebar) |sidebar| {
            const widget = sidebar.as(gtk.Widget);
            const visible = widget.getVisible();
            widget.setVisible(!visible);
        }
    }

    /// Show the AI input dialog
    pub fn show(self: *Self, win: *Window, selected_text: ?[]const u8, terminal_context: ?[]const u8) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        if (priv.selected_text) |old| alloc.free(old);
        if (priv.terminal_context) |old| alloc.free(old);

        priv.selected_text = if (selected_text) |text|
            alloc.dupe(u8, text) catch null
        else
            null;

        priv.terminal_context = if (terminal_context) |ctx|
            alloc.dupe(u8, ctx) catch null
        else
            null;

        priv.window = win;

        // Update context label if we have selection
        if (priv.selected_text != null) {
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
        self.updateProviderDropdown();
        self.updateModelDropdown();
        self.updateApiKeyEntry();
        self.updateEndpointEntry();
        const cfg = config.get();

        // Initialize assistant
        if (cfg.@"ai-enabled") {
            const provider_enum: ?AiAssistant.Provider = if (cfg.@"ai-provider") |p| switch (p) {
                .openai => .openai,
                .anthropic => .anthropic,
                .ollama => .ollama,
                .custom => .custom,
            } else null;

            if (provider_enum) |provider| {
                const ai_config = AiAssistant.Config{
                    .enabled = cfg.@"ai-enabled",
                    .provider = provider,
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
                } else |err| {
                    const ai_enabled = cfg.@"ai-enabled";
                    const ai_provider_str = if (cfg.@"ai-provider") |prov| @tagName(prov) else "null";
                    const ai_api_key_len = cfg.@"ai-api-key".len;
                    const ai_model_str = cfg.@"ai-model";
                    const ai_endpoint_str = cfg.@"ai-endpoint";
                    log.err("AI assistant init failed: error={s}, ai_enabled={}, ai_provider={s}, ai_api_key_len={d}, ai_model={s}, ai_endpoint={s}", .{
                        @errorName(err),
                        ai_enabled,
                        ai_provider_str,
                        ai_api_key_len,
                        ai_model_str,
                        ai_endpoint_str,
                    });
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
    fn closed(dialog: *adw.Dialog, self: *Self) callconv(.c) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Clear the response store
        const n_items: c_uint = @intCast(priv.response_store.nItems());
        if (n_items > 0) {
            priv.response_store.remove(0, n_items);
        }

        // Clear the input buffer
        priv.input_buffer.setText("", -1);

        self.hideSuggestions();

        if (priv.selected_text) |text| alloc.free(text);
        priv.selected_text = null;

        if (priv.terminal_context) |ctx| alloc.free(ctx);
        priv.terminal_context = null;

        priv.window = null;

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
                        result[end] == '='))
                {
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
    fn send_clicked(button: *gtk.Button, self: *Self) callconv(.c) void {
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
            var start: gtk.TextIter = undefined;
            var end: gtk.TextIter = undefined;
            priv.input_buffer.getBounds(&start, &end);
            break :blk priv.input_buffer.getText(&start, &end, false);
        };
        defer glib.free(@ptrCast(@constCast(input_text.ptr)));

        // Build the final prompt
        const selection = priv.selected_text orelse "";
        var context = priv.terminal_context orelse "";

        // Add knowledge rules suggestions to context
        if (priv.knowledge_rules) |*kr| {
            const cwd_result = std.fs.cwd().realpathAlloc(alloc, ".");
            const cwd = cwd_result catch ".";
            defer if (cwd_result) |c| alloc.free(c);

            // Build command history
            var command_history = ArrayList([]const u8).init(alloc);
            defer {
                for (command_history.items) |_| {}
                command_history.deinit();
            }

            // Get recent commands (simplified - in real implementation, get from terminal history)
            if (input_text.len > 0) {
                command_history.append(input_text) catch {};
            }

            const rule_context = KnowledgeRulesManager.RuleContext{
                .cwd = cwd,
                .last_command = if (input_text.len > 0) input_text else null,
                .command_history = command_history,
                .last_output = null,
                .git_state = null,
                .env_vars = StringHashMap([]const u8).init(alloc),
            };
            defer rule_context.env_vars.deinit();

            const knowledge_suggestions = kr.getSuggestions(rule_context, 3) catch null;
            if (knowledge_suggestions) |ksugs| {
                defer {
                    for (ksugs.items) |*s| s.deinit(alloc);
                    ksugs.deinit();
                }

                if (ksugs.items.len > 0) {
                    var context_buf = ArrayList(u8).init(alloc);
                    defer context_buf.deinit();

                    if (context.len > 0) {
                        try context_buf.writer().print("{s}\n\n", .{context});
                    }

                    try context_buf.writer().print("Knowledge-based suggestions:\n", .{});
                    for (ksugs.items, 0..) |sug, i| {
                        if (i >= 3) break;
                        try context_buf.writer().print("  • {s} (confidence: {d:.1}%)\n", .{ sug.text, sug.confidence * 100.0 });
                    }

                    if (context.len > 0) {
                        alloc.free(context);
                    }
                    const new_context = try context_buf.toOwnedSlice();
                    context = new_context;
                    if (priv.terminal_context) |old| alloc.free(old);
                    priv.terminal_context = new_context;
                }
            }
        }

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

        // Update progress bar with error handling
        if (priv.progress_bar) |pb| {
            // Check if widget is still valid
            if (self.as(gtk.Widget).isVisible()) {
                pb.setVisible(@intFromBool(true));
                pb.setFraction(0.0);
                pb.setText("Initializing...");
            }
        }

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
        errdefer alloc.free(prompt_dupe);

        const context_dupe = if (context.len > 0) alloc.dupe(u8, context) catch null;
        errdefer if (context_dupe) |c| alloc.free(c);

        // Ref config to keep it alive for the thread
        _ = config.ref();
        errdefer config.unref();

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
        errdefer self.unref();

        const thread = std.Thread.spawn(.{}, aiThreadMain, .{ctx}) catch |err| {
            log.err("Failed to spawn AI request thread: {}", .{err});

            // Manual cleanup since errdefer doesn't fire on normal return
            // (errdefer only fires on error return paths)
            alloc.free(prompt_dupe);
            if (context_dupe) |c| alloc.free(c);
            config.unref();
            self.unref();

            // Reset UI state
            priv.loading_label.setVisible(false);
            priv.response_view.setVisible(true);
            priv.send_sensitive = true;
            self.notify(properties.send_sensitive.name);

            // Show error to user
            const error_msg = std.fmt.allocPrintZ(alloc, "Error: Failed to process request. System may be overloaded. Please try again.", .{}) catch {
                // If allocation fails, use static string
                _ = self.addResponse("Error: Request failed") catch |add_err| {
                    log.err("Failed to add error response: {}", .{add_err});
                };
                return;
            };
            defer alloc.free(error_msg);
            _ = self.addResponse(error_msg) catch |add_err| {
                log.err("Failed to add error response: {}", .{add_err});
            };
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
            const stream_init = alloc.create(StreamChunk) catch |err| {
                log.err("Failed to allocate stream init chunk: {}", .{err});

                // Send error result to main thread to notify user
                const ai_result = alloc.create(AiResult) catch {
                    // Even cleanup failed - release ref since callback won't run
                    ctx.input_mode.unref();
                    return;
                };
                ai_result.* = .{
                    .input_mode = ctx.input_mode,
                    .response = null,
                    .err = std.fmt.allocPrintZ(alloc, "Error: Out of memory. Please close other apps and try again.", .{}) catch "Error: Memory allocation failed",
                    .is_final = true,
                };
                // Check if idleAdd succeeded - if not, clean up
                if (glib.idleAdd(aiResultCallback, ai_result) == 0) {
                    log.err("Failed to add idle callback for AI error result - memory may leak");
                    // Clean up the result since callback won't run
                    if (ai_result.err) |e| alloc.free(e);
                    alloc.destroy(ai_result);
                    // Release ref since callback won't run
                    ctx.input_mode.unref();
                }
                return;
            };
            stream_init.* = .{
                .input_mode = ctx.input_mode,
                .content = "",
                .done = false,
            };
            // Check if idleAdd succeeded - if not, clean up
            if (glib.idleAdd(streamInitCallback, stream_init) == 0) {
                log.err("Failed to add idle callback for stream init - memory may leak");
                alloc.destroy(stream_init);
            }

            // Create callback with closure using global state
            const callback = struct {
                fn inner(chunk: ai_client.StreamChunk) void {
                    streaming_state_mutex.lock();
                    const input_mode = streaming_state;
                    streaming_state_mutex.unlock();

                    if (input_mode) |mode| {
                        const alloc_cb = Application.default().allocator();
                        const stream_chunk = alloc_cb.create(StreamChunk) catch |err| {
                            log.err("Failed to allocate stream chunk: {}", .{err});
                            return;
                        };
                        stream_chunk.* = .{
                            .input_mode = mode,
                            .content = alloc_cb.dupe(u8, chunk.content) catch |err| {
                                log.err("Failed to duplicate stream content: {}", .{err});
                                alloc_cb.destroy(stream_chunk);
                                return;
                            },
                            .done = chunk.done,
                        };

                        // Update progress bar if available
                        if (mode) |m| {
                            const priv_cb = getPriv(m);
                            if (priv_cb.progress_bar) |pb| {
                                // Check if widget is still valid before accessing
                                if (!m.as(gtk.Widget).isVisible()) return;

                                if (!chunk.done) {
                                    pb.setVisible(@intFromBool(true));
                                    // Estimate progress based on content length (rough estimate)
                                    const progress = @min(0.95, @as(f32, @floatFromInt(chunk.content.len)) / 10000.0);
                                    pb.setFraction(progress);

                                    // Update progress text
                                    const progress_text = std.fmt.allocPrintZ(alloc_cb, "Processing... {d}%", .{@intFromFloat(progress * 100.0)}) catch {
                                        pb.setText("Processing...");
                                        return;
                                    };
                                    defer alloc_cb.free(progress_text);
                                    pb.setText(progress_text);
                                } else {
                                    pb.setFraction(1.0);
                                    pb.setText("Complete");

                                    // Hide after a short delay with error handling
                                    const pb_ref = pb.ref();
                                    if (glib.timeoutAdd(500, struct {
                                        fn callback(pb_ptr: *gtk.ProgressBar) callconv(.c) c_int {
                                            // Check if widget is still valid before hiding
                                            if (pb_ptr.as(gtk.Widget).isVisible()) {
                                                pb_ptr.setVisible(false);
                                                pb_ptr.setFraction(0.0);
                                                pb_ptr.setText("");
                                            }
                                            pb_ptr.unref();
                                            return 0; // G_SOURCE_REMOVE
                                        }
                                    }.callback, pb_ref, .{}) == 0) {
                                        // Failed to add timeout, clean up immediately
                                        pb.setVisible(false);
                                        pb.setFraction(0.0);
                                        pb.setText("");
                                        pb.unref();
                                    }
                                }
                            }
                        }
                        // Check if idleAdd succeeded - if not, clean up
                        if (glib.idleAdd(streamChunkCallback, stream_chunk) == 0) {
                            log.err("Failed to add idle callback for stream chunk - memory may leak");
                            // Clean up the stream chunk since callback won't run
                            alloc.free(stream_chunk.content);
                            alloc.destroy(stream_chunk);
                        }
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
                // On error, send error result.
                // Note: If streaming succeeded, ref was released in streamChunkCallback.
                // If streaming failed (we're here), ref has NOT been released yet.
                const ai_result = alloc.create(AiResult) catch {
                    // Even cleanup failed - release ref since callback won't run
                    ctx.input_mode.unref();
                    return;
                };
                ai_result.* = .{
                    .input_mode = ctx.input_mode,
                    .response = null,
                    .err = std.fmt.allocPrintZ(alloc, "Error: {s}", .{@errorName(err)}) catch null,
                    .is_final = true,
                };
                // Check if idleAdd succeeded - if not, clean up
                if (glib.idleAdd(aiResultCallback, ai_result) == 0) {
                    log.err("Failed to add idle callback for AI error result - memory may leak");
                    // Clean up the result since callback won't run
                    if (ai_result.err) |e| alloc.free(e);
                    alloc.destroy(ai_result);
                    // Release ref since callback won't run
                    ctx.input_mode.unref();
                }
            };
        } else {
            // Use blocking API
            const result = assistant.process(ctx.prompt, ctx.context);

            const ai_result = alloc.create(AiResult) catch {
                // Even cleanup failed - release ref since callback won't run
                ctx.input_mode.unref();
                return;
            };
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

            // Check if idleAdd succeeded - if not, clean up
            if (glib.idleAdd(aiResultCallback, ai_result) == 0) {
                log.err("Failed to add idle callback for AI result - memory may leak");
                // Clean up the result since callback won't run
                if (ai_result.response) |r| alloc.free(r);
                if (ai_result.err) |e| alloc.free(e);
                alloc.destroy(ai_result);
                // Release ref since callback won't run
                ctx.input_mode.unref();
            }
        }
    }

    /// Callback to initialize streaming state on main thread
    fn streamInitCallback(data: ?*anyopaque) callconv(.c) c_int {
        const chunk: *StreamChunk = @ptrCast(@alignCast(data));
        const alloc = Application.default().allocator();
        defer alloc.destroy(chunk);

        const self = chunk.input_mode;

        // Verify this callback corresponds to the current streaming session.
        // If streaming_state != self, either streaming was cancelled or a different
        // session started. This is NOT a complete use-after-free guard - it only
        // detects stale callbacks from cancelled sessions. The actual lifetime
        // guarantee comes from the ref() call in send_clicked before spawning the thread.
        const current_streaming_state = getStreamingState();

        if (current_streaming_state != self) {
            log.debug("streamInitCallback: streaming state mismatch (expected during cancellation)", .{});
            // Reset UI state to prevent frozen loading indicator
            const priv = getPriv(self);
            priv.loading_label.setVisible(false);
            priv.response_view.setVisible(true);
            return 0;
        }

        // Also check if disposed flag is set (additional protection)
        const priv = getPriv(self);
        if (priv.is_disposed) {
            log.debug("streamInitCallback: widget is disposed", .{});
            return 0;
        }

        // Now safe to check widget visibility since streaming state is valid
        if (!self.as(gtk.Widget).isVisible()) return 0;

        // Initialize streaming response buffer
        priv.streaming_response = std.array_list.Managed(u8).init(alloc);

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
    fn streamChunkCallback(data: ?*anyopaque) callconv(.c) c_int {
        const chunk: *StreamChunk = @ptrCast(@alignCast(data));
        const alloc = Application.default().allocator();
        defer alloc.destroy(chunk);
        defer if (chunk.content.len > 0) alloc.free(chunk.content);

        const self = chunk.input_mode;

        // Verify this callback corresponds to the current streaming session.
        // If streaming_state != self, either streaming was cancelled or a different
        // session started. This is NOT a complete use-after-free guard - it only
        // detects stale callbacks from cancelled sessions. The actual lifetime
        // guarantee comes from the ref() call in send_clicked before spawning the thread.
        const current_streaming_state = getStreamingState();

        // If streaming state doesn't match, we're in an inconsistent state
        if (current_streaming_state != self) {
            log.debug("streamChunkCallback: streaming state mismatch (expected during cancellation), ignoring chunk", .{});
            return 0;
        }

        // Also check if disposed flag is set (additional protection)
        const priv = getPriv(self);
        if (priv.is_disposed) {
            log.debug("streamChunkCallback: widget is disposed", .{});
            return 0;
        }

        // Now safe to check widget visibility since streaming state is valid
        if (!self.as(gtk.Widget).isVisible()) return 0;

        // If the user cancelled, ignore intermediate chunks but still handle the final "done" chunk.
        if (priv.request_cancelled and !chunk.done) return 0; // G_SOURCE_REMOVE

        if (priv.streaming_response) |*buffer| {
            // Append new content to buffer
            buffer.appendSlice(chunk.content) catch |err| {
                log.err("Failed to append streaming chunk, aborting stream: {}", .{err});
                // Clean up streaming state on error to prevent memory leaks
                buffer.deinit();
                priv.streaming_response = null;
                // Keep the item in store but clear our reference to it
                priv.streaming_response_item = null;
                return 0; // G_SOURCE_REMOVE to stop processing
            };

            // Update the response item with new content
            if (priv.streaming_response_item) |item| {
                const item_priv = gobject.ext.getPriv(item, &ResponseItem.ResponseItemPrivate.offset);

                // Convert accumulated content to sentinel-terminated string for markup
                const content_z_for_markup = alloc.dupeZ(u8, buffer.items) catch |err| {
                    log.err("Failed to allocate string for markup: {}", .{err});
                    return 1; // Continue, try again next chunk
                };
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
                item.content = markup.ptr;

                // Trigger UI update by notifying the store
                priv.response_store.itemsChanged(@intCast(priv.response_store.nItems() - 1), 1, 1);
            }

            // If this is the final chunk, clean up streaming state
            if (chunk.done) {
                if (priv.streaming_response_item) |item| {
                    const item_priv = gobject.ext.getPriv(item, &ResponseItem.ResponseItemPrivate.offset);

                    // Convert accumulated content to sentinel-terminated string for command extraction
                    if (alloc.dupeZ(u8, buffer.items)) |cz| {
                        defer alloc.free(cz);

                        if (extractCommandFromMarkdown(alloc, cz)) |command| {
                            if (item_priv.command.len == 0 and command.len > 0) {
                                item_priv.command = command;
                            } else if (command.len > 0) {
                                alloc.free(command);
                            }
                        } else |err| {
                            log.err("Failed to extract command: {}", .{err});
                        }
                    } else |err| {
                        log.err("Failed to allocate string for command extraction: {}", .{err});
                    }
                    // Clear the reference but don't free the item (store owns it)
                    priv.streaming_response_item = null;
                }

                // Convert accumulated content to sentinel-terminated string for auto-execute
                // IMPORTANT: Must do this BEFORE buffer.deinit() to avoid use-after-free
                const content_z_for_auto_execute = alloc.dupeZ(u8, buffer.items) catch |err| blk: {
                    log.err("Failed to allocate string for auto-execute: {}", .{err});
                    break :blk null;
                };

                // Now safe to clean up the buffer
                buffer.deinit();
                priv.streaming_response = null;

                // Hide progress bar on completion
                if (priv.progress_bar) |pb| {
                    if (self.as(gtk.Widget).isVisible()) {
                        pb.setVisible(false);
                        pb.setFraction(0.0);
                        pb.setText("");
                    }
                }

                // Re-enable send button
                if (priv.config) |cfg| {
                    self.setConfig(cfg);
                }

                // Update stop/regenerate button state
                priv.stop_sensitive = false;
                priv.regenerate_sensitive = priv.last_prompt != null;
                self.notify(properties.stop_sensitive.name);
                self.notify(properties.regenerate_sensitive.name);

                // Execute auto-execute if we have content
                if (content_z_for_auto_execute) |content_z| {
                    defer alloc.free(content_z);
                    self.maybeAutoExecuteFromResponse(content_z);
                }

                // Release the ref acquired in send_clicked.
                // In the streaming path, this is the final callback, so we release here.
                // (In the non-streaming path, aiResultCallback releases it.)
                self.unref();
            }
        }

        return 0; // G_SOURCE_REMOVE
    }

    fn aiResultCallback(data: ?*anyopaque) callconv(.c) c_int {
        const result: *AiResult = @ptrCast(@alignCast(data));
        const alloc = Application.default().allocator();
        defer alloc.destroy(result);
        defer if (result.response) |r| alloc.free(r);
        defer if (result.err) |e| alloc.free(e);

        const self = result.input_mode;
        defer self.unref();

        const priv = getPriv(self);

        // Check if widget is still valid before accessing
        if (!self.as(gtk.Widget).isVisible()) {
            // Widget was destroyed, clean up and exit
            // Note: result.response and result.err are freed by defer statements above
            return 0; // G_SOURCE_REMOVE
        }

        // Also check if disposed flag is set (additional protection)
        if (priv.is_disposed) {
            log.debug("aiResultCallback: widget is disposed", .{});
            return 0;
        }

        // Verify streaming state is cleared (non-streaming result)
        const current_streaming_state = getStreamingState();

        // For non-streaming results, streaming_state should be null
        if (current_streaming_state != null) {
            log.warn("aiResultCallback: unexpected streaming state for non-streaming result", .{});
            // Clear the streaming state if it's us
            if (current_streaming_state == self) {
                streaming_state_mutex.lock();
                streaming_state = null;
                streaming_state_mutex.unlock();
            }
        }

        priv.loading_label.setVisible(false);
        priv.response_view.setVisible(true);

        // Hide progress bar on completion/error
        if (priv.progress_bar) |pb| {
            pb.setVisible(false);
            pb.setFraction(0.0);
            pb.setText("");
        }

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
        // Note: defer statements above handle freeing result.response and result.err
        if (priv.request_cancelled) {
            return 0; // G_SOURCE_REMOVE
        }

        if (result.response) |resp| {
            if (self.addResponse(resp)) {
                self.maybeAutoExecuteFromResponse(resp);
            } else |add_err| {
                log.err("Failed to add response: {}", .{add_err});
                // Note: defer handles freeing resp
            }
        } else if (result.err) |err_msg| {
            _ = self.addResponse(err_msg) catch |add_err| {
                log.err("Failed to add error response: {}", .{add_err});
                // Note: defer handles freeing err_msg
            };
        }

        return 0; // G_SOURCE_REMOVE
    }

    /// Signal handler for template dropdown change
    fn template_changed(dropdown: *gtk.DropDown, param: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        _ = dropdown;
        _ = param;
        _ = self;
        // Template change handling can be added here if needed
        // For now, the template is applied when sending
    }

    /// Signal handler for provider dropdown change
    fn providerChanged(dropdown: *gtk.DropDown, param: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        _ = dropdown;
        _ = param;
        const priv = getPriv(self);
        if (priv.updating_provider_dropdown) return;

        const cfg_obj = priv.config orelse return;

        const selected = priv.provider_dropdown.getSelected();
        if (selected >= 4) return; // 4 providers: OpenAI, Anthropic, Ollama, Custom

        const provider_enum: ?enum { openai, anthropic, ollama, custom } = switch (selected) {
            0 => .openai,
            1 => .anthropic,
            2 => .ollama,
            3 => .custom,
            else => null,
        };

        if (provider_enum) |p| {
            const cfg_mut = cfg_obj.getMut();
            cfg_mut.@"ai-provider" = switch (p) {
                .openai => .openai,
                .anthropic => .anthropic,
                .ollama => .ollama,
                .custom => .custom,
            };

            // Update model dropdown for new provider
            self.updateModelDropdown();

            // Update endpoint visibility
            priv.endpoint_row.setVisible(@intFromBool(p == .custom));

            // Reinitialize assistant with new provider
            self.setConfig(cfg_obj);
        }
    }

    /// Signal handler for API key entry change
    fn apiKeyChanged(entry: *gtk.Entry, param: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        _ = entry;
        _ = param;
        const priv = getPriv(self);
        if (priv.updating_api_key) return;

        const cfg_obj = priv.config orelse return;
        const cfg_mut = cfg_obj.getMut();

        const text = priv.api_key_entry.getText();
        cfg_mut.@"ai-api-key" = cfg_mut.arenaAlloc().dupe(u8, text) catch return;

        // Update send button sensitivity
        const enabled = cfg_obj.get().@"ai-enabled";
        const provider = cfg_obj.get().@"ai-provider" != null;
        const api_key = cfg_mut.@"ai-api-key".len > 0 or
            (cfg_obj.get().@"ai-provider" != null and cfg_obj.get().@"ai-provider".? == .ollama);

        priv.send_sensitive = enabled and provider and api_key;
        self.notify(properties.send_sensitive.name);
    }

    /// Signal handler for API key toggle button
    fn apiKeyToggleClicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        _ = button;
        const priv = getPriv(self);
        const visible = priv.api_key_entry.getVisibility();
        priv.api_key_entry.setVisibility(@intFromBool(!visible));

        const icon_name = if (visible) "eye-not-looking-symbolic" else "eye-open-negative-filled-symbolic";
        priv.api_key_toggle.setIconName(icon_name);
    }

    /// Signal handler for endpoint entry change
    fn endpointChanged(entry: *gtk.Entry, param: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        _ = entry;
        _ = param;
        const priv = getPriv(self);
        const cfg_obj = priv.config orelse return;
        const cfg_mut = cfg_obj.getMut();

        const text = priv.endpoint_entry.getText();
        cfg_mut.@"ai-endpoint" = cfg_mut.arenaAlloc().dupe(u8, text) catch return;

        // Reinitialize assistant with new endpoint
        self.setConfig(cfg_obj);
    }

    /// Signal handler for model dropdown change
    fn model_changed(dropdown: *gtk.DropDown, param: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        _ = dropdown;
        _ = param;
        const priv = getPriv(self);
        if (priv.updating_model_dropdown) return;

        const cfg_obj = priv.config orelse return;
        const cfg = cfg_obj.get();
        const provider = cfg.@"ai-provider" orelse return;

        const models: []const [:0]const u8 = switch (provider) {
            .openai => &[_][:0]const u8{
                "gpt-4o",
                "gpt-4o-mini",
                "gpt-4-turbo",
                "gpt-4",
                "gpt-3.5-turbo",
            },
            .anthropic => &[_][:0]const u8{
                "claude-3-5-sonnet-20241022",
                "claude-3-opus-20240229",
                "claude-3-sonnet-20240229",
                "claude-3-haiku-20240307",
            },
            .ollama => &[_][:0]const u8{
                "llama3",
                "llama3:8b",
                "llama3:70b",
                "mistral",
                "codellama",
                "phi",
            },
            .custom => &[_][:0]const u8{
                "custom-model",
            },
        };

        const selected = priv.model_dropdown.getSelected();
        if (selected >= @as(c_uint, @intCast(models.len))) return;

        const model_name = models[@intCast(selected)];
        const cfg_mut = cfg_obj.getMut();
        if (std.mem.eql(u8, cfg_mut.@"ai-model", model_name)) return;

        // Note: config strings are owned by the config's arena allocator.
        cfg_mut.@"ai-model" = cfg_mut.arenaAlloc().dupe(u8, model_name) catch return;

        // Reinitialize assistant with new model
        self.setConfig(cfg_obj);
    }

    /// Update model dropdown based on current provider and configuration.
    fn updateModelDropdown(self: *Self) void {
        const priv = getPriv(self);
        const cfg_obj = priv.config orelse {
            priv.model_dropdown.as(gtk.Widget).setSensitive(@intFromBool(false));
            return;
        };

        priv.updating_model_dropdown = true;
        defer priv.updating_model_dropdown = false;

        const cfg = cfg_obj.get();
        const provider = cfg.@"ai-provider" orelse {
            priv.model_dropdown.as(gtk.Widget).setSensitive(@intFromBool(false));
            return;
        };

        const models: []const [:0]const u8 = switch (provider) {
            .openai => &[_][:0]const u8{
                "gpt-4o",
                "gpt-4o-mini",
                "gpt-4-turbo",
                "gpt-4",
                "gpt-3.5-turbo",
            },
            .anthropic => &[_][:0]const u8{
                "claude-3-5-sonnet-20241022",
                "claude-3-opus-20240229",
                "claude-3-sonnet-20240229",
                "claude-3-haiku-20240307",
            },
            .ollama => &[_][:0]const u8{
                "llama3",
                "llama3:8b",
                "llama3:70b",
                "mistral",
                "codellama",
                "phi",
            },
            .custom => &[_][:0]const u8{
                "custom-model",
            },
        };

        const alloc = Application.default().allocator();
        const model_list = ext.StringList.create(alloc, models) catch |err| {
            log.err("Failed to create model string list: {}", .{err});
            priv.model_dropdown.as(gtk.Widget).setSensitive(@intFromBool(false));
            return;
        };
        priv.model_dropdown.setModel(model_list.as(gio.ListModel));

        // Ensure selection matches config (or choose a default).
        const current_model = cfg.@"ai-model";
        var selected_idx: usize = 0;
        var found = false;
        if (current_model.len > 0) {
            for (models, 0..) |name, i| {
                if (std.mem.eql(u8, name, current_model)) {
                    selected_idx = i;
                    found = true;
                    break;
                }
            }
        }

        // If no model is set or it doesn't match provider, default to the first model.
        if (!found and models.len > 0) {
            const cfg_mut = cfg_obj.getMut();
            cfg_mut.@"ai-model" = cfg_mut.arenaAlloc().dupe(u8, models[0]) catch {};
        }

        priv.model_dropdown.setSelected(@intCast(selected_idx));
        priv.model_dropdown.as(gtk.Widget).setSensitive(@intFromBool(models.len > 0));
    }

    /// Update provider dropdown based on current configuration
    fn updateProviderDropdown(self: *Self) void {
        const priv = getPriv(self);
        const cfg_obj = priv.config orelse {
            priv.provider_dropdown.as(gtk.Widget).setSensitive(@intFromBool(false));
            return;
        };

        priv.updating_provider_dropdown = true;
        defer priv.updating_provider_dropdown = false;

        const providers = &[_][:0]const u8{
            "OpenAI",
            "Anthropic",
            "Ollama",
            "Custom",
        };

        const alloc = Application.default().allocator();
        const provider_list = ext.StringList.create(alloc, providers) catch |err| {
            log.err("Failed to create provider string list: {}", .{err});
            priv.provider_dropdown.as(gtk.Widget).setSensitive(@intFromBool(false));
            return;
        };
        priv.provider_dropdown.setModel(provider_list.as(gio.ListModel));

        // Set selection based on config
        const cfg = cfg_obj.get();
        const current_provider = cfg.@"ai-provider";
        var selected_idx: usize = 0;
        if (current_provider) |p| {
            selected_idx = switch (p) {
                .openai => 0,
                .anthropic => 1,
                .ollama => 2,
                .custom => 3,
            };
        }

        priv.provider_dropdown.setSelected(@intCast(selected_idx));
        priv.provider_dropdown.as(gtk.Widget).setSensitive(@intFromBool(true));

        // Update endpoint visibility
        priv.endpoint_row.setVisible(@intFromBool(current_provider != null and current_provider.? == .custom));
    }

    /// Update API key entry based on current configuration
    fn updateApiKeyEntry(self: *Self) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();
        const cfg_obj = priv.config orelse {
            priv.api_key_entry.setSensitive(@intFromBool(false));
            return;
        };

        priv.updating_api_key = true;
        defer priv.updating_api_key = false;

        const cfg = cfg_obj.get();
        const api_key_z = alloc.dupeZ(u8, cfg.@"ai-api-key") catch {
            priv.api_key_entry.setSensitive(@intFromBool(false));
            return;
        };
        defer alloc.free(api_key_z);
        priv.api_key_entry.setText(api_key_z);
        priv.api_key_entry.setSensitive(@intFromBool(true));
    }

    /// Update endpoint entry based on current configuration
    fn updateEndpointEntry(self: *Self) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();
        const cfg_obj = priv.config orelse {
            priv.endpoint_entry.setSensitive(@intFromBool(false));
            return;
        };

        const cfg = cfg_obj.get();
        const endpoint_z = alloc.dupeZ(u8, cfg.@"ai-endpoint") catch {
            priv.endpoint_entry.setSensitive(@intFromBool(false));
            return;
        };
        defer alloc.free(endpoint_z);
        priv.endpoint_entry.setText(endpoint_z);
        priv.endpoint_entry.setSensitive(@intFromBool(true));
    }

    /// Register actions for the menu
    fn registerActions(self: *Self) void {
        const action_group = gio.SimpleActionGroup.new();

        // Workflows action
        const workflows_action = gio.SimpleAction.new("show-workflows", null);
        _ = gio.SimpleAction.signals.activate.connect(workflows_action, *Self, showWorkflowsDialog, self, .{});
        action_group.addAction(workflows_action);

        // Notebooks action
        const notebooks_action = gio.SimpleAction.new("show-notebooks", null);
        _ = gio.SimpleAction.signals.activate.connect(notebooks_action, *Self, showNotebooksDialog, self, .{});
        action_group.addAction(notebooks_action);

        // History action
        const history_action = gio.SimpleAction.new("show-history", null);
        _ = gio.SimpleAction.signals.activate.connect(history_action, *Self, showHistoryDialog, self, .{});
        action_group.addAction(history_action);

        // Settings action
        const settings_action = gio.SimpleAction.new("show-settings", null);
        _ = gio.SimpleAction.signals.activate.connect(settings_action, *Self, showSettingsDialog, self, .{});
        action_group.addAction(settings_action);

        // Keyboard shortcuts action
        const shortcuts_action = gio.SimpleAction.new("show-shortcuts", null);
        _ = gio.SimpleAction.signals.activate.connect(shortcuts_action, *Self, showKeyboardShortcuts, self, .{});
        action_group.addAction(shortcuts_action);

        // Export/Import action
        const export_import_action = gio.SimpleAction.new("show-export-import", null);
        _ = gio.SimpleAction.signals.activate.connect(export_import_action, *Self, showExportImport, self, .{});
        action_group.addAction(export_import_action);

        // Notification center action
        const notifications_action = gio.SimpleAction.new("show-notifications", null);
        _ = gio.SimpleAction.signals.activate.connect(notifications_action, *Self, showNotificationCenter, self, .{});
        action_group.addAction(notifications_action);

        // Theme customization action
        const theme_action = gio.SimpleAction.new("show-theme-customization", null);
        _ = gio.SimpleAction.signals.activate.connect(theme_action, *Self, showThemeCustomization, self, .{});
        action_group.addAction(theme_action);

        // Session sharing action
        const session_action = gio.SimpleAction.new("show-session-sharing", null);
        _ = gio.SimpleAction.signals.activate.connect(session_action, *Self, showSessionSharing, self, .{});
        action_group.addAction(session_action);

        // Command analysis action
        const analysis_action = gio.SimpleAction.new("show-command-analysis", null);
        _ = gio.SimpleAction.signals.activate.connect(analysis_action, *Self, showCommandAnalysis, self, .{});
        action_group.addAction(analysis_action);

        // Insert action group
        self.as(gtk.Widget).insertActionGroup("ai", action_group.as(gio.ActionGroup));
    }

    /// Show keyboard shortcuts dialog
    fn showKeyboardShortcuts(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const win = priv.window orelse return;
        const dialog = KeyboardShortcutsDialog.new();
        dialog.show(win);
    }

    /// Show workflows dialog
    fn showWorkflowsDialog(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const dialog = adw.MessageDialog.new(null, "Workflows", "Manage and execute AI workflows");
        dialog.setBody("Workflow management will be available in a future update.");
        dialog.addResponse("ok", "OK");
        dialog.setDefaultResponse("ok");
        dialog.setCloseResponse("ok");
        dialog.setModal(@intFromBool(true));

        const win = priv.window orelse return;
        dialog.setTransientFor(win.as(gtk.Window));
        dialog.present();
    }

    /// Show notebooks dialog
    fn showNotebooksDialog(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const dialog = adw.MessageDialog.new(null, "Notebooks", "Create and manage executable notebooks");
        dialog.setBody("Notebook management will be available in a future update.");
        dialog.addResponse("ok", "OK");
        dialog.setDefaultResponse("ok");
        dialog.setCloseResponse("ok");
        dialog.setModal(@intFromBool(true));

        const win = priv.window orelse return;
        dialog.setTransientFor(win.as(gtk.Window));
        dialog.present();
    }

    /// Show history dialog
    fn showHistoryDialog(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const dialog = adw.MessageDialog.new(null, "Command History", "View and search command history");
        dialog.setBody("Rich command history will be available in a future update.");
        dialog.addResponse("ok", "OK");
        dialog.setDefaultResponse("ok");
        dialog.setCloseResponse("ok");
        dialog.setModal(@intFromBool(true));

        const win = priv.window orelse return;
        dialog.setTransientFor(win.as(gtk.Window));
        dialog.present();
    }

    /// Show settings dialog
    fn showSettingsDialog(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const win = priv.window orelse return;
        const dialog = AiSettingsDialog.new();
        if (priv.config) |cfg| {
            dialog.setConfig(cfg);
        }
        dialog.show(win);
    }

    fn showExportImport(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const win = priv.window orelse return;
        const dialog = priv.export_import_dialog orelse blk: {
            const new_dialog = ExportImportDialog.new();
            priv.export_import_dialog = new_dialog;
            break :blk new_dialog;
        };
        dialog.show(win);
    }

    fn showNotificationCenter(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const win = priv.window orelse return;
        const center = priv.notification_center orelse blk: {
            const new_center = NotificationCenter.new();
            priv.notification_center = new_center;
            break :blk new_center;
        };
        center.show(win);
    }

    fn showThemeCustomization(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const win = priv.window orelse return;
        const dialog = priv.theme_customization_dialog orelse blk: {
            const new_dialog = ThemeCustomizationDialog.new();
            priv.theme_customization_dialog = new_dialog;
            break :blk new_dialog;
        };
        dialog.show(win);
    }

    fn showSessionSharing(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const win = priv.window orelse return;
        const dialog = priv.session_sharing_dialog orelse blk: {
            const new_dialog = SessionSharingDialog.new();
            priv.session_sharing_dialog = new_dialog;
            break :blk new_dialog;
        };
        dialog.show(win);
    }

    fn showCommandAnalysis(action: *gio.SimpleAction, param: ?*glib.Variant, self: *Self) callconv(.c) void {
        _ = action;
        _ = param;
        const priv = getPriv(self);

        const win = priv.window orelse return;
        const dialog = priv.command_analysis_dialog orelse blk: {
            const new_dialog = CommandAnalysisDialog.new();
            priv.command_analysis_dialog = new_dialog;
            break :blk new_dialog;
        };
        dialog.show(win);
    }

    /// Signal handler for stop button click
    fn stop_clicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        _ = button;
        const priv = getPriv(self);

        // Set cancellation flag
        priv.request_cancelled = true;

        // Exit loading state immediately; any late result will be ignored.
        priv.loading_label.setVisible(false);
        priv.response_view.setVisible(true);

        // Hide progress bar when stopping
        if (priv.progress_bar) |pb| {
            if (self.as(gtk.Widget).isVisible()) {
                pb.setVisible(false);
                pb.setFraction(0.0);
                pb.setText("");
            }
        }

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
    fn regenerate_clicked(button: *gtk.Button, self: *Self) callconv(.c) void {
        _ = button;
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Check if we have a previous request to regenerate
        if (priv.last_prompt == null) {
            log.warn("Regenerate clicked but no previous prompt available", .{});
            // Show error to user
            _ = self.addResponse("Error: No previous prompt to regenerate. Please send a new request first.") catch {};
            return;
        }

        // Validate assistant is initialized
        if (priv.assistant == null) {
            log.err("Regenerate clicked but assistant is not initialized", .{});
            _ = self.addResponse("Error: AI Assistant not initialized. Please check your configuration.") catch {};
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

        // Update progress bar with error handling
        if (priv.progress_bar) |pb| {
            if (self.as(gtk.Widget).isVisible()) {
                pb.setVisible(@intFromBool(true));
                pb.setFraction(0.0);
                pb.setText("Regenerating...");
            }
        }

        // Prepare thread context with last prompt/context
        const prompt_dupe = alloc.dupe(u8, priv.last_prompt.?) catch |err| {
            log.err("Failed to duplicate prompt for regeneration: {}", .{err});
            // Reset UI state
            priv.loading_label.setVisible(false);
            priv.response_view.setVisible(true);
            priv.send_sensitive = true;
            priv.regenerate_sensitive = true;
            self.notify(properties.send_sensitive.name);
            self.notify(properties.regenerate_sensitive.name);

            // Hide progress bar on error
            if (priv.progress_bar) |pb| {
                pb.setVisible(false);
                pb.setFraction(0.0);
                pb.setText("");
            }

            _ = self.addResponse("Error: Failed to prepare regeneration request. Please try again.") catch {};
            return;
        };

        const context_dupe: ?[]const u8 = blk: {
            if (priv.last_context) |ctx| {
                if (ctx.len > 0) {
                    break :blk alloc.dupe(u8, ctx) catch |err| {
                        log.warn("Failed to duplicate context for regeneration: {}, continuing without context", .{err});
                        break :blk null;
                    };
                }
            }
            break :blk null;
        };

        const config = priv.config orelse {
            log.err("Regenerate clicked but config is null", .{});
            alloc.free(prompt_dupe);
            if (context_dupe) |c| alloc.free(c);

            // Reset UI state
            priv.loading_label.setVisible(false);
            priv.response_view.setVisible(true);
            priv.send_sensitive = true;
            priv.regenerate_sensitive = true;
            self.notify(properties.send_sensitive.name);
            self.notify(properties.regenerate_sensitive.name);

            // Hide progress bar on error
            if (priv.progress_bar) |pb| {
                pb.setVisible(false);
                pb.setFraction(0.0);
                pb.setText("");
            }

            _ = self.addResponse("Error: Configuration not available. Please check your settings.") catch {};
            return;
        };
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
            log.err("Failed to spawn AI request thread for regeneration: {}", .{err});
            alloc.free(prompt_dupe);
            if (context_dupe) |c| alloc.free(c);
            config.unref();
            self.unref();

            // Reset UI state
            priv.loading_label.setVisible(false);
            priv.response_view.setVisible(true);
            priv.send_sensitive = true;
            priv.regenerate_sensitive = true;
            priv.stop_sensitive = false;
            self.notify(properties.send_sensitive.name);
            self.notify(properties.regenerate_sensitive.name);
            self.notify(properties.stop_sensitive.name);

            // Hide progress bar on error
            if (priv.progress_bar) |pb| {
                if (self.as(gtk.Widget).isVisible()) {
                    pb.setVisible(false);
                    pb.setFraction(0.0);
                    pb.setText("");
                }
            }

            // Show error to user
            const error_msg = std.fmt.allocPrintZ(alloc, "Error: Failed to regenerate request. System may be overloaded. Please try again.", .{}) catch {
                // If allocation fails, use static string
                _ = self.addResponse("Error: Regeneration failed") catch |add_err| {
                    log.err("Failed to add error response: {}", .{add_err});
                };
                return;
            };
            defer alloc.free(error_msg);
            _ = self.addResponse(error_msg) catch |add_err| {
                log.err("Failed to add error response: {}", .{add_err});
            };
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
        var free_redacted = redacted_content.ptr != content.ptr;
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

        // Add to chat history
        if (priv.chat_history_store) |history_store| {
            // Create a simple history entry (can be enhanced later)
            const history_entry = gobject.Object.new(gobject.Object) catch {};
            history_store.append(history_entry);
        }

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
        var result = std.array_list.Managed(u8).init(alloc);
        errdefer result.deinit();

        const input_len = input.len;

        const Escape = struct {
            fn append(out: *std.array_list.Managed(u8), text: []const u8) !void {
                for (text) |ch| {
                    switch (ch) {
                        '<' => try out.appendSlice("&lt;"),
                        '>' => try out.appendSlice("&gt;"),
                        '&' => try out.appendSlice("&amp;"),
                        else => try out.append(ch),
                    }
                }
            }
        };

        var i: usize = 0;
        while (i < input_len) {
            const at_line_start = i == 0 or input[i - 1] == '\n';

            // Code blocks: ```lang\ncode\n```
            if (i + 3 <= input_len and std.mem.eql(u8, input[i .. i + 3], "```")) {
                const fence_end = std.mem.indexOfPos(u8, input, i + 3, "```") orelse input_len;

                // Skip optional language identifier line (```bash)
                var code_start = i + 3;
                while (code_start < fence_end and input[code_start] != '\n') code_start += 1;
                if (code_start < fence_end and input[code_start] == '\n') code_start += 1;

                try result.appendSlice("<tt>");
                try Escape.append(&result, input[code_start..fence_end]);
                try result.appendSlice("</tt>");

                i = if (fence_end < input_len) fence_end + 3 else input_len;
                if (i < input_len and input[i] == '\n') {
                    try result.append('\n');
                    i += 1;
                } else {
                    try result.append('\n');
                }
                continue;
            }

            // Headers: # text
            if (at_line_start and input[i] == '#') {
                var level: usize = 0;
                while (i + level < input_len and input[i + level] == '#') level += 1;
                if (level <= 6 and i + level < input_len and input[i + level] == ' ') {
                    const header_start = i + level + 1;
                    const rel_end = std.mem.indexOfScalar(u8, input[header_start..], '\n') orelse (input_len - header_start);
                    const sizes = [_][]const u8{ "xx-large", "x-large", "large", "medium", "small", "x-small" };
                    const size = sizes[@min(level - 1, sizes.len - 1)];
                    try result.print("<span size=\"{s}\"><b>", .{size});
                    try Escape.append(&result, input[header_start .. header_start + rel_end]);
                    try result.appendSlice("</b></span>\n");
                    i = header_start + rel_end;
                    if (i < input_len and input[i] == '\n') i += 1;
                    continue;
                }
            }

            // Simple bullet lists: "- " or "* " at line start
            if (at_line_start and i + 2 <= input_len and (input[i] == '-' or input[i] == '*') and input[i + 1] == ' ') {
                try result.appendSlice("• ");
                i += 2;
                continue;
            }

            // Inline code: `code`
            if (input[i] == '`') {
                const end_idx = std.mem.indexOfPos(u8, input, i + 1, "`") orelse {
                    try Escape.append(&result, input[i .. i + 1]);
                    i += 1;
                    continue;
                };
                try result.appendSlice("<tt>");
                try Escape.append(&result, input[i + 1 .. end_idx]);
                try result.appendSlice("</tt>");
                i = end_idx + 1;
                continue;
            }

            // Bold: **text** or __text__
            if (i + 2 <= input_len and (std.mem.eql(u8, input[i..@min(i + 2, input_len)], "**") or std.mem.eql(u8, input[i..@min(i + 2, input_len)], "__"))) {
                const marker = input[i .. i + 2];
                const end_idx = std.mem.indexOfPos(u8, input, i + 2, marker) orelse {
                    try Escape.append(&result, input[i .. i + 1]);
                    i += 1;
                    continue;
                };
                try result.appendSlice("<b>");
                try Escape.append(&result, input[i + 2 .. end_idx]);
                try result.appendSlice("</b>");
                i = end_idx + 2;
                continue;
            }

            // Italic: *text* or _text_ (avoid bold markers)
            if (i + 1 < input_len and (input[i] == '*' or input[i] == '_') and (input[i + 1] != '*' and input[i + 1] != '_')) {
                const marker = input[i .. i + 1];
                const end_idx = std.mem.indexOfPos(u8, input, i + 1, marker) orelse {
                    try Escape.append(&result, input[i .. i + 1]);
                    i += 1;
                    continue;
                };
                try result.appendSlice("<i>");
                try Escape.append(&result, input[i + 1 .. end_idx]);
                try result.appendSlice("</i>");
                i = end_idx + 1;
                continue;
            }

            try Escape.append(&result, input[i .. i + 1]);
            i += 1;
        }

        return result.toOwnedSliceSentinel(0);
    }

    /// Handle text buffer changes for prompt suggestions
    fn inputBufferChanged(buffer: *gtk.TextBuffer, self: *Self) callconv(.c) void {
        _ = buffer;
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Get current text
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        priv.input_buffer.getBounds(&start, &end);
        const text = priv.input_buffer.getText(&start, &end, false);
        defer glib.free(@ptrCast(@constCast(text.ptr)));

        // Check if we should show suggestions
        var has_suggestions = false;

        if (priv.prompt_suggestion_service) |*service| {
            if (!service.shouldShowSuggestion(text, 2)) {
                // Check knowledge rules even if prompt suggestions aren't shown
            } else {
                // Get prompt suggestions
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
                    has_suggestions = true;
                }
            }
        }

        // Also check knowledge rules for context-aware suggestions
        if (priv.knowledge_rules) |*kr| {
            const cwd_result = std.fs.cwd().realpathAlloc(alloc, ".");
            const cwd = cwd_result catch ".";
            defer if (cwd_result) |c| alloc.free(c);

            var command_history = ArrayList([]const u8).init(alloc);
            defer {
                for (command_history.items) |_| {}
                command_history.deinit();
            }

            if (text.len > 0) {
                command_history.append(text) catch {};
            }

            const rule_context = KnowledgeRulesManager.RuleContext{
                .cwd = cwd,
                .last_command = if (text.len > 0) text else null,
                .command_history = command_history,
                .last_output = null,
                .git_state = null,
                .env_vars = StringHashMap([]const u8).init(alloc),
            };
            defer rule_context.env_vars.deinit();

            const knowledge_suggestions = kr.getSuggestions(rule_context, 3) catch null;
            if (knowledge_suggestions) |ksugs| {
                defer {
                    for (ksugs.items) |*s| s.deinit(alloc);
                    ksugs.deinit();
                }

                if (ksugs.items.len > 0 and !has_suggestions) {
                    // Convert knowledge suggestions to prompt suggestions for display
                    var prompt_suggestions = ArrayList(PromptSuggestion).init(alloc);
                    defer {
                        for (prompt_suggestions.items) |*s| s.deinit(alloc);
                        prompt_suggestions.deinit();
                    }

                    for (ksugs.items) |ksug| {
                        const prompt_sug = PromptSuggestion{
                            .completion = try alloc.dupe(u8, ksug.text),
                            .description = try std.fmt.allocPrint(alloc, "Knowledge rule: {s} ({d:.0}% confidence)", .{ ksug.rule_name, ksug.confidence * 100.0 }),
                            .kind = .command,
                            .confidence = ksug.confidence,
                        };
                        prompt_suggestions.append(prompt_sug) catch continue;
                    }

                    if (prompt_suggestions.items.len > 0) {
                        self.showSuggestions(prompt_suggestions.items);
                        has_suggestions = true;
                    }
                }
            }
        }

        if (!has_suggestions) {
            self.hideSuggestions();
        }
    }

    /// Show suggestion popup with list of suggestions
    fn showSuggestions(self: *Self, suggestions: []const PromptSuggestion) void {
        const priv = getPriv(self);
        const alloc = Application.default().allocator();

        // Clear current suggestions
        for (priv.current_suggestions.items) |*suggestion| {
            suggestion.deinit(alloc);
        }
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
                const completion_z = alloc.dupeZ(u8, suggestion.completion) catch continue;
                defer alloc.free(completion_z);
                const desc_z = alloc.dupeZ(u8, suggestion.description) catch continue;
                defer alloc.free(desc_z);

                const row = gtk.ListBoxRow.new();
                const box = gtk.Box.new(gtk.Orientation.vertical, 4);
                const box_widget = box.as(gtk.Widget);
                box_widget.setMarginTop(6);
                box_widget.setMarginBottom(6);
                box_widget.setMarginStart(12);
                box_widget.setMarginEnd(12);

                // Completion text
                const completion_label = gtk.Label.new(completion_z);
                completion_label.setXAlign(0);
                completion_label.setUseMarkup(false);
                completion_label.getStyleContext().addClass("heading");
                box.append(completion_label.as(gtk.Widget));

                // Description text
                const desc_label = gtk.Label.new(desc_z);
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
    fn suggestionRowActivated(list: *gtk.ListBox, row: *gtk.ListBoxRow, self: *Self) callconv(.c) void {
        _ = list;
        const priv = getPriv(self);

        // Get selected index
        const index = row.getIndex();
        if (index < 0 or index >= @as(c_int, @intCast(priv.current_suggestions.items.len))) return;

        const suggestion = priv.current_suggestions.items[@intCast(index)];

        // Insert suggestion into input buffer
        var start: gtk.TextIter = undefined;
        var end: gtk.TextIter = undefined;
        priv.input_buffer.getBounds(&start, &end);
        priv.input_buffer.delete(&start, &end);
        priv.input_buffer.insert(
            &start,
            @ptrCast(suggestion.completion.ptr),
            @intCast(suggestion.completion.len),
        );

        // Hide suggestions
        self.hideSuggestions();

        log.info("Applied prompt suggestion: {s}", .{suggestion.completion});
    }
};
