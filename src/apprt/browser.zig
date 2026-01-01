//! Application runtime for the browser version of Ghostty. The browser
//! version is when Ghostty is compiled to WebAssembly and runs within a
//! web browser environment. This provides a complete terminal emulator
//! that can be embedded in web applications.

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const input = @import("../input.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const CoreApp = @import("../App.zig");
const CoreInspector = @import("../inspector/main.zig").Inspector;
const CoreSurface = @import("../Surface.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

const log = std.log.scoped(.browser_window);

pub const resourcesDir = internal_os.resourcesDir;

/// Browser-specific C API for interacting with JavaScript
pub const CAPI = struct {
    /// JavaScript console logging
    extern fn ghostty_js_log(level: c_int, message: [*c]const u8) void;

    /// Request animation frame callback
    extern fn ghostty_js_request_animation_frame(callback: *const fn () callconv(.c) void) void;

    /// Get canvas context
    extern fn ghostty_js_get_canvas_context(canvas_id: [*c]const u8) ?*anyopaque;

    /// Set canvas size
    extern fn ghostty_js_set_canvas_size(canvas_id: [*c]const u8, width: u32, height: u32) void;

    /// Get clipboard content
    extern fn ghostty_js_read_clipboard(callback: *const fn ([*c]const u8) callconv(.c) void) void;

    /// Write to clipboard
    extern fn ghostty_js_write_clipboard(content: [*c]const u8) void;

    /// Focus callback
    extern fn ghostty_js_set_focus_callback(callback: *const fn (bool) callconv(.c) void) void;

    /// Resize callback
    extern fn ghostty_js_set_resize_callback(callback: *const fn (u32, u32) callconv(.c) void) void;
};

pub const App = struct {
    /// Browser-specific options for the application
    pub const Options = struct {
        /// Canvas ID in the DOM where the terminal will be rendered
        canvas_id: [:0]const u8 = "ghostty-canvas",

        /// Initial font size in points
        font_size: f32 = 12.0,

        /// Enable clipboard access (requires user permission)
        enable_clipboard: bool = true,

        /// Userdata that can be passed to JavaScript callbacks
        userdata: ?*anyopaque = null,
    };

    core_app: *CoreApp,
    opts: Options,
    keymap: input.Keymap,
    config: Config,

    /// Animation frame state
    animation_frame_requested: bool = false,

    /// JavaScript callbacks
    focus_callback: ?*const fn (bool) callconv(.c) void = null,
    resize_callback: ?*const fn (u32, u32) callconv(.c) void = null,

    pub fn init(
        self: *App,
        core_app: *CoreApp,
        config: *const Config,
        opts: Options,
    ) !void {
        // Clone the config
        const alloc = core_app.alloc;
        var config_clone = try config.clone(alloc);
        errdefer config_clone.deinit();

        var keymap = try input.Keymap.init();
        errdefer keymap.deinit();

        self.* = .{
            .core_app = core_app,
            .config = config_clone,
            .opts = opts,
            .keymap = keymap,
        };

        // Set up JavaScript callbacks
        self.setupJSCallbacks();
    }

    pub fn terminate(self: *App) void {
        self.keymap.deinit();
        self.config.deinit();
        global_app_ptr = null;
    }

    fn setupJSCallbacks(self: *App) void {
        _ = self; // TODO: Implement when JavaScript integration is available
    }

    /// Global pointer for JavaScript callbacks (WASM limitation)
    var global_app_ptr: ?*App = null;

    pub fn run(self: *App) !void {
        // Store global pointer for callbacks
        global_app_ptr = self;

        // Browser runtime doesn't have a traditional event loop
        // It's driven by JavaScript events and requestAnimationFrame
        log.info("Browser runtime initialized", .{});
    }

    pub fn wakeup(self: *App) void {
        // Request animation frame if not already requested
        if (!self.animation_frame_requested) {
            self.animation_frame_requested = true;
            CAPI.ghostty_js_request_animation_frame(struct {
                fn animationFrame() callconv(.c) void {
                    const app = @as(*App, @ptrCast(@alignCast(global_app_ptr))).?;
                    app.animation_frame_requested = false;
                    app.tick() catch |err| {
                        log.err("error in animation frame: {}", .{err});
                    };
                }
            }.animationFrame);
        }
    }

    fn tick(self: *App) !void {
        // Process any pending events
        self.core_app.tick(self) catch |err| {
            log.err("error in app tick: {}", .{err});
        };
    }

    pub fn focusEvent(self: *App, focused: bool) void {
        self.core_app.focusEvent(focused);
    }

    pub fn performAction(
        _: *App,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        log.debug("browser performAction: {}={}", .{ action, value });

        // Handle browser-specific actions based on target
        switch (target) {
            .app => {
                // App-level actions
                switch (action) {
                    else => {
                        log.debug("unhandled browser app action: {}", .{action});
                        return true;
                    },
                }
            },
            .surface => {
                // Surface-level actions
                switch (action) {
                    .set_title => {
                        const title = value.title;
                        // This would call JavaScript to update document.title
                        log.debug("setting title: {s}", .{title});
                        return true;
                    },
                    else => {
                        log.debug("unhandled browser surface action: {}", .{action});
                        return true;
                    },
                }
            },
        }
    }

    pub fn performIpc(
        _: Allocator,
        _: apprt.ipc.Target,
        comptime action: apprt.ipc.Action.Key,
        _: apprt.ipc.Action.Value(action),
    ) !bool {
        // Browser runtime doesn't support IPC
        return false;
    }

    pub fn hasGlobalKeybinds(self: *const App) bool {
        var it = self.config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            switch (entry.value_ptr.*) {
                .leader => {},
                inline .leaf, .leaf_chained => |leaf| if (leaf.flags.global) return true,
            }
        }
        return false;
    }

    pub fn reloadKeymap(self: *App) !void {
        try self.keymap.reload();
    }

    pub fn keyboardLayout(_: *const App) input.KeyboardLayout {
        // Browser doesn't support keyboard layout detection
        return .unknown;
    }

    pub fn redrawInspector(self: *App, surface: *Surface) void {
        _ = self;
        surface.queueInspectorRender();
    }
};

pub const Surface = struct {
    app: *App,
    userdata: ?*anyopaque = null,
    core_surface: CoreSurface,
    content_scale: apprt.ContentScale,
    size: apprt.SurfaceSize,
    cursor_pos: apprt.CursorPos,
    inspector: ?*Inspector = null,

    /// Canvas context for WebGL rendering
    canvas_context: ?*anyopaque = null,

    /// Current title
    title: ?[:0]const u8 = null,

    pub const Options = struct {
        /// Canvas ID for this surface
        canvas_id: [:0]const u8,
        /// Userdata passed to callbacks
        userdata: ?*anyopaque = null,
        /// Scale factor (DPI)
        scale_factor: f64 = 1,
        /// Font size in points
        font_size: f32 = 0,
        /// Working directory
        working_directory: ?[*:0]const u8 = null,
        /// Command to run
        command: ?[*:0]const u8 = null,
        /// Environment variables
        env_vars: ?[*]apprt.Embedded.EnvVar = null,
        env_var_count: usize = 0,
        /// Initial input
        initial_input: ?[*:0]const u8 = null,
        /// Wait after command
        wait_after_command: bool = false,
    };

    pub fn init(self: *Surface, app: *App, opts: Options) !void {
        self.* = .{
            .app = app,
            .userdata = opts.userdata,
            .core_surface = undefined,
            .content_scale = .{
                .x = @floatCast(opts.scale_factor),
                .y = @floatCast(opts.scale_factor),
            },
            .size = .{ .width = 800, .height = 600 },
            .cursor_pos = .{ .x = -1, .y = -1 },
            .canvas_context = null,
        };

        // Add to app's core surfaces
        try app.core_app.addSurface(self);
        errdefer app.core_app.deleteSurface(self);

        // Get canvas context from JavaScript
        const canvas_id = std.mem.sliceTo(opts.canvas_id, 0);
        self.canvas_context = CAPI.ghostty_js_get_canvas_context(canvas_id.ptr);
        if (self.canvas_context == null) {
            log.err("failed to get canvas context for id: {s}", .{canvas_id});
            return error.CanvasContextNotFound;
        }

        // Set initial canvas size
        CAPI.ghostty_js_set_canvas_size(canvas_id.ptr, self.size.width, self.size.height);

        // Initialize core surface
        var config = try apprt.surface.newConfig(app.core_app, &app.config);
        defer config.deinit();

        // Apply working directory if provided
        if (opts.working_directory) |c_wd| {
            const wd = std.mem.sliceTo(c_wd, 0);
            if (wd.len > 0) wd: {
                // Browser doesn't have direct filesystem access
                // This would need to be handled via JavaScript File System Access API
                log.warn("working directory not supported in browser: {s}", .{wd});
                break :wd;
            }
        }

        // Apply command if provided
        if (opts.command) |c_command| {
            const cmd = std.mem.sliceTo(c_command, 0);
            if (cmd.len > 0) {
                config.command = .{ .shell = cmd };
                config.@"wait-after-command" = true;
            }
        }

        // Initialize the core surface
        try self.core_surface.init(
            app.core_app.alloc,
            &config,
            app.core_app,
            app,
            self,
        );
        errdefer self.core_surface.deinit();

        // Set font size if specified
        if (opts.font_size != 0) {
            var font_size = self.core_surface.font_size;
            font_size.points = opts.font_size;
            try self.core_surface.setFontSize(font_size);
        }
    }

    pub fn deinit(self: *Surface) void {
        self.freeInspector();
        if (self.title) |v| self.app.core_app.alloc.free(v);
        self.app.core_app.deleteSurface(self);
        self.core_surface.deinit();
    }

    pub fn initInspector(self: *Surface) !*Inspector {
        if (self.inspector) |v| return v;
        const alloc = self.app.core_app.alloc;
        const inspector = try alloc.create(Inspector);
        errdefer alloc.destroy(inspector);
        inspector.* = try .init(self);
        self.inspector = inspector;
        return inspector;
    }

    pub fn freeInspector(self: *Surface) void {
        if (self.inspector) |v| {
            v.deinit();
            self.app.core_app.alloc.destroy(v);
            self.inspector = null;
        }
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *const Surface) *App {
        return self.app;
    }

    pub fn close(_: *const Surface, process_alive: bool) void {
        _ = process_alive;
        log.info("closing surface", .{});
        // Browser surfaces are managed by JavaScript
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        return self.content_scale;
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return self.size;
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        return self.title;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        return switch (clipboard_type) {
            .standard => self.app.opts.enable_clipboard,
            .selection, .primary => false, // Browser doesn't support selection clipboard
        };
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        if (!self.supportsClipboard(clipboard_type)) return false;

        // TODO: Implement JavaScript clipboard API integration
        _ = state;
        log.warn("clipboard not yet implemented in browser runtime", .{});
        return false;
    }

    fn completeClipboardRequest(
        self: *Surface,
        str: [:0]const u8,
        state: *apprt.ClipboardRequest,
        confirmed: bool,
    ) void {
        const alloc = self.app.core_app.alloc;
        self.core_surface.completeClipboardRequest(
            state.*,
            str,
            confirmed,
        ) catch |err| {
            log.err("error completing clipboard request: {}", .{err});
        };
        alloc.destroy(state);
    }

    pub fn setClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        if (!self.supportsClipboard(clipboard_type)) return;

        // TODO: Implement JavaScript clipboard API integration
        _ = contents;
        _ = confirm;
        log.warn("clipboard not yet implemented in browser runtime", .{});
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn refresh(self: *Surface) void {
        self.app.wakeup();
    }

    pub fn draw(self: *Surface) void {
        self.core_surface.draw() catch |err| {
            log.err("error in draw: {}", .{err});
        };
    }

    pub fn updateContentScale(self: *Surface, x: f64, y: f64) void {
        const x_scaled = @max(1, if (std.math.isNan(x)) 1 else x);
        const y_scaled = @max(1, if (std.math.isNan(y)) 1 else y);

        self.content_scale = .{
            .x = @floatCast(x_scaled),
            .y = @floatCast(y_scaled),
        };

        self.core_surface.contentScaleCallback(self.content_scale) catch |err| {
            log.err("error in content scale callback: {}", .{err});
        };
    }

    pub fn updateSize(self: *Surface, width: u32, height: u32) void {
        if (self.size.width == width and self.size.height == height) return;

        self.size = .{ .width = width, .height = height };
        self.core_surface.sizeCallback(self.size) catch |err| {
            log.err("error in size callback: {}", .{err});
        };

        // Update canvas size via JavaScript
        CAPI.ghostty_js_set_canvas_size(self.app.opts.canvas_id.ptr, width, height);
    }

    pub fn colorSchemeCallback(self: *Surface, scheme: apprt.ColorScheme) void {
        self.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("error setting color scheme: {}", .{err});
        };
    }

    pub fn mouseButtonCallback(
        self: *Surface,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) bool {
        return self.core_surface.mouseButtonCallback(action, button, mods) catch |err| {
            log.err("error in mouse button callback: {}", .{err});
            return false;
        };
    }

    pub fn mousePressureCallback(
        self: *Surface,
        stage: input.MousePressureStage,
        pressure: f64,
    ) void {
        self.core_surface.mousePressureCallback(stage, pressure) catch |err| {
            log.err("error in mouse pressure callback: {}", .{err});
        };
    }

    pub fn scrollCallback(
        self: *Surface,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        self.core_surface.scrollCallback(xoff, yoff, mods) catch |err| {
            log.err("error in scroll callback: {}", .{err});
        };
    }

    pub fn cursorPosCallback(
        self: *Surface,
        x: f64,
        y: f64,
        mods: input.Mods,
    ) void {
        self.cursor_pos = self.cursorPosToPixels(.{
            .x = @floatCast(x),
            .y = @floatCast(y),
        }) catch |err| {
            log.err("error converting cursor pos: {}", .{err});
            return;
        };

        self.core_surface.cursorPosCallback(self.cursor_pos, mods) catch |err| {
            log.err("error in cursor pos callback: {}", .{err});
        };
    }

    pub fn preeditCallback(self: *Surface, preedit_: ?[]const u8) void {
        _ = self.core_surface.preeditCallback(preedit_) catch |err| {
            log.err("error in preedit callback: {}", .{err});
        };
    }

    pub fn textCallback(self: *Surface, text: []const u8) void {
        _ = self.core_surface.textCallback(text) catch |err| {
            log.err("error in text callback: {}", .{err});
        };
    }

    pub fn focusCallback(self: *Surface, focused: bool) void {
        self.core_surface.focusCallback(focused) catch |err| {
            log.err("error in focus callback: {}", .{err});
        };
    }

    pub fn occlusionCallback(self: *Surface, visible: bool) void {
        self.core_surface.occlusionCallback(visible) catch |err| {
            log.err("error in occlusion callback: {}", .{err});
        };
    }

    fn queueInspectorRender(self: *Surface) void {
        self.app.wakeup();
    }

    pub fn newSurfaceOptions(self: *const Surface) apprt.Surface.Options {
        const font_size: f32 = font_size: {
            if (!self.app.config.@"window-inherit-font-size") break :font_size 0;
            break :font_size self.core_surface.font_size.points;
        };
        _ = font_size; // TODO: Use this when implementing surface options
        return .{};
    }

    pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
        const alloc = self.app.core_app.alloc;
        var env = try internal_os.getEnvMap(alloc);
        errdefer env.deinit();

        // Browser environment doesn't have typical shell environment
        // Set minimal environment for web terminal
        try env.put("TERM", "xterm-256color");
        try env.put("COLORTERM", "truecolor");

        return env;
    }

    fn cursorPosToPixels(self: *const Surface, pos: apprt.CursorPos) !apprt.CursorPos {
        const scale = try self.getContentScale();
        return .{ .x = pos.x * scale.x, .y = pos.y * scale.y };
    }
};

/// Inspector for browser runtime
pub const Inspector = struct {
    surface: *Surface,

    pub fn init(surface: *Surface) !Inspector {
        surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector: {}", .{err});
        };
        return .{ .surface = surface };
    }

    pub fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
    }

    pub fn queueRender(self: *Inspector) void {
        self.surface.queueInspectorRender();
    }

    pub fn updateSize(self: *Inspector, width: u32, height: u32) void {
        _ = width;
        _ = height;
        self.queueRender();
    }

    pub fn updateContentScale(self: *Inspector, x: f64, y: f64) void {
        _ = x;
        _ = y;
        self.queueRender();
    }

    pub fn mouseButtonCallback(
        self: *Inspector,
        action: input.MouseButtonState,
        button: input.MouseButton,
        mods: input.Mods,
    ) void {
        _ = action;
        _ = button;
        _ = mods;
        self.queueRender();
    }

    pub fn mousePosCallback(self: *Inspector, x: f64, y: f64) void {
        _ = x;
        _ = y;
        self.queueRender();
    }

    pub fn scrollCallback(
        self: *Inspector,
        xoff: f64,
        yoff: f64,
        mods: input.ScrollMods,
    ) void {
        _ = xoff;
        _ = yoff;
        _ = mods;
        self.queueRender();
    }

    pub fn focusCallback(self: *Inspector, focused: bool) void {
        _ = focused;
        self.queueRender();
    }

    pub fn textCallback(self: *Inspector, text: []const u8) void {
        _ = text;
        self.queueRender();
    }

    pub fn keyCallback(
        self: *Inspector,
        action: input.Action,
        key: input.Key,
        mods: input.Mods,
    ) !void {
        _ = action;
        _ = key;
        _ = mods;
        self.queueRender();
    }
};

test {
    _ = App;
    _ = Surface;
    _ = Inspector;
}
