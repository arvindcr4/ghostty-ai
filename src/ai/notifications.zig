//! Notification System Module
//!
//! This module provides desktop notifications for long-running AI tasks.
//! It supports platform-specific notification APIs:
//! - macOS: NSUserNotification via Objective-C bridge
//! - Linux: libnotify / D-Bus notifications
//! - Cross-platform: In-terminal notifications and sounds

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const builtin = @import("builtin");

const log = std.log.scoped(.ai_notifications);

/// Notification urgency levels
pub const Urgency = enum {
    low,
    normal,
    critical,

    pub fn toLinuxUrgency(self: Urgency) []const u8 {
        return switch (self) {
            .low => "low",
            .normal => "normal",
            .critical => "critical",
        };
    }
};

/// Notification category for grouping
pub const NotificationCategory = enum {
    ai_response,
    command_complete,
    error,
    warning,
    info,
    workflow_progress,
};

/// A notification to display
pub const Notification = struct {
    title: []const u8,
    body: []const u8,
    urgency: Urgency,
    category: NotificationCategory,
    timeout_ms: i32,
    icon: ?[]const u8,
    actions: ArrayList(NotificationAction),
    timestamp: i64,

    pub const NotificationAction = struct {
        id: []const u8,
        label: []const u8,
    };

    pub fn init(alloc: Allocator, title: []const u8, body: []const u8) !Notification {
        return .{
            .title = try alloc.dupe(u8, title),
            .body = try alloc.dupe(u8, body),
            .urgency = .normal,
            .category = .info,
            .timeout_ms = 5000,
            .icon = null,
            .actions = ArrayList(NotificationAction).init(alloc),
            .timestamp = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *const Notification, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
        if (self.icon) |icon| alloc.free(icon);
        for (self.actions.items) |action| {
            alloc.free(action.id);
            alloc.free(action.label);
        }
        @constCast(&self.actions).deinit();
    }

    pub fn setIcon(self: *Notification, alloc: Allocator, icon: []const u8) !void {
        if (self.icon) |old| alloc.free(old);
        self.icon = try alloc.dupe(u8, icon);
    }

    pub fn addAction(self: *Notification, alloc: Allocator, id: []const u8, label: []const u8) !void {
        try self.actions.append(.{
            .id = try alloc.dupe(u8, id),
            .label = try alloc.dupe(u8, label),
        });
    }
};

/// Notification history entry
const NotificationHistoryEntry = struct {
    notification: Notification,
    delivered: bool,
    clicked: bool,
    dismissed: bool,
};

/// Notification Manager configuration
pub const NotificationConfig = struct {
    /// Enable notifications
    enabled: bool = true,
    /// Enable sounds with notifications
    sounds_enabled: bool = true,
    /// Default timeout in milliseconds
    default_timeout_ms: i32 = 5000,
    /// Suppress notifications when terminal is focused
    suppress_when_focused: bool = true,
    /// Group similar notifications
    group_similar: bool = true,
    /// Do not disturb mode
    do_not_disturb: bool = false,
    /// Notification sound file path
    sound_file: ?[]const u8 = null,
};

/// Notification Manager - main interface for notifications
pub const NotificationManager = struct {
    alloc: Allocator,
    config: NotificationConfig,
    history: ArrayList(NotificationHistoryEntry),
    pending_notifications: ArrayList(Notification),
    is_terminal_focused: bool,

    /// Callback for notification actions
    on_action: ?*const fn (notification_id: []const u8, action_id: []const u8, user_data: ?*anyopaque) void,
    callback_user_data: ?*anyopaque,

    /// Initialize notification manager
    pub fn init(alloc: Allocator) NotificationManager {
        return .{
            .alloc = alloc,
            .config = .{},
            .history = ArrayList(NotificationHistoryEntry).init(alloc),
            .pending_notifications = ArrayList(Notification).init(alloc),
            .is_terminal_focused = true,
            .on_action = null,
            .callback_user_data = null,
        };
    }

    pub fn deinit(self: *NotificationManager) void {
        for (self.history.items) |*entry| {
            entry.notification.deinit(self.alloc);
        }
        self.history.deinit();

        for (self.pending_notifications.items) |*notif| {
            notif.deinit(self.alloc);
        }
        self.pending_notifications.deinit();
    }

    /// Configure the notification manager
    pub fn configure(self: *NotificationManager, config: NotificationConfig) void {
        self.config = config;
    }

    /// Send a notification
    pub fn sendNotification(
        self: *NotificationManager,
        title: []const u8,
        body: []const u8,
        urgency: Urgency,
    ) !void {
        if (!self.config.enabled) return;
        if (self.config.do_not_disturb and urgency != .critical) return;

        // Suppress if terminal is focused (unless critical)
        if (self.config.suppress_when_focused and self.is_terminal_focused and urgency != .critical) {
            log.debug("Notification suppressed (terminal focused): {s}", .{title});
            return;
        }

        var notification = try Notification.init(self.alloc, title, body);
        notification.urgency = urgency;
        notification.timeout_ms = self.config.default_timeout_ms;

        try self.deliverNotification(&notification);

        // Add to history
        try self.history.append(.{
            .notification = notification,
            .delivered = true,
            .clicked = false,
            .dismissed = false,
        });
    }

    /// Send a notification with category
    pub fn sendCategorizedNotification(
        self: *NotificationManager,
        title: []const u8,
        body: []const u8,
        urgency: Urgency,
        category: NotificationCategory,
    ) !void {
        if (!self.config.enabled) return;
        if (self.config.do_not_disturb and urgency != .critical) return;

        var notification = try Notification.init(self.alloc, title, body);
        notification.urgency = urgency;
        notification.category = category;
        notification.timeout_ms = self.config.default_timeout_ms;

        // Set appropriate icon based on category
        const icon = switch (category) {
            .ai_response => "dialog-information",
            .command_complete => "dialog-ok",
            .error => "dialog-error",
            .warning => "dialog-warning",
            .info => "dialog-information",
            .workflow_progress => "emblem-synchronizing",
        };
        try notification.setIcon(self.alloc, icon);

        try self.deliverNotification(&notification);

        try self.history.append(.{
            .notification = notification,
            .delivered = true,
            .clicked = false,
            .dismissed = false,
        });
    }

    /// Deliver notification using platform-specific method
    fn deliverNotification(self: *NotificationManager, notification: *const Notification) !void {
        // Try platform-specific delivery first
        const delivered = switch (builtin.os.tag) {
            .macos => self.deliverMacOS(notification),
            .linux => self.deliverLinux(notification),
            else => false,
        };

        if (!delivered) {
            // Fall back to terminal bell and log
            self.deliverFallback(notification);
        }

        // Play sound if enabled
        if (self.config.sounds_enabled) {
            self.playNotificationSound();
        }
    }

    /// Deliver notification on macOS using osascript
    fn deliverMacOS(self: *const NotificationManager, notification: *const Notification) bool {
        _ = self;

        // Use osascript for notifications
        const script = std.fmt.allocPrint(
            std.heap.page_allocator,
            "display notification \"{s}\" with title \"{s}\"",
            .{ notification.body, notification.title },
        ) catch return false;
        defer std.heap.page_allocator.free(script);

        var child = std.process.Child.init(
            &[_][]const u8{ "osascript", "-e", script },
            std.heap.page_allocator,
        );
        child.spawn() catch return false;
        _ = child.wait() catch return false;

        log.info("Delivered macOS notification: {s}", .{notification.title});
        return true;
    }

    /// Deliver notification on Linux using notify-send
    fn deliverLinux(self: *const NotificationManager, notification: *const Notification) bool {
        _ = self;

        var args = ArrayList([]const u8).init(std.heap.page_allocator);
        defer args.deinit();

        args.append("notify-send") catch return false;
        args.append("-u") catch return false;
        args.append(notification.urgency.toLinuxUrgency()) catch return false;

        if (notification.icon) |icon| {
            args.append("-i") catch return false;
            args.append(icon) catch return false;
        }

        const timeout_str = std.fmt.allocPrint(
            std.heap.page_allocator,
            "{d}",
            .{notification.timeout_ms},
        ) catch return false;
        defer std.heap.page_allocator.free(timeout_str);

        args.append("-t") catch return false;
        args.append(timeout_str) catch return false;
        args.append(notification.title) catch return false;
        args.append(notification.body) catch return false;

        var child = std.process.Child.init(args.items, std.heap.page_allocator);
        child.spawn() catch return false;
        _ = child.wait() catch return false;

        log.info("Delivered Linux notification: {s}", .{notification.title});
        return true;
    }

    /// Fallback notification (terminal bell + log)
    fn deliverFallback(_: *const NotificationManager, notification: *const Notification) void {
        // Ring terminal bell
        const stdout = std.io.getStdOut().writer();
        stdout.writeByte(0x07) catch {}; // BEL character

        // Log the notification
        const urgency_str = switch (notification.urgency) {
            .low => "LOW",
            .normal => "NORMAL",
            .critical => "CRITICAL",
        };
        log.info("[{s}] {s}: {s}", .{ urgency_str, notification.title, notification.body });
    }

    /// Play notification sound
    fn playNotificationSound(self: *const NotificationManager) void {
        if (self.config.sound_file) |sound_path| {
            // Try to play custom sound
            switch (builtin.os.tag) {
                .macos => {
                    var child = std.process.Child.init(
                        &[_][]const u8{ "afplay", sound_path },
                        std.heap.page_allocator,
                    );
                    child.spawn() catch {};
                },
                .linux => {
                    var child = std.process.Child.init(
                        &[_][]const u8{ "paplay", sound_path },
                        std.heap.page_allocator,
                    );
                    child.spawn() catch {
                        // Try aplay as fallback
                        var child2 = std.process.Child.init(
                            &[_][]const u8{ "aplay", sound_path },
                            std.heap.page_allocator,
                        );
                        child2.spawn() catch {};
                    };
                },
                else => {},
            }
        } else {
            // Play default system sound
            switch (builtin.os.tag) {
                .macos => {
                    var child = std.process.Child.init(
                        &[_][]const u8{ "afplay", "/System/Library/Sounds/Glass.aiff" },
                        std.heap.page_allocator,
                    );
                    child.spawn() catch {};
                },
                else => {},
            }
        }
    }

    /// Notify about AI response completion
    pub fn notifyResponseComplete(
        self: *NotificationManager,
        success: bool,
    ) !void {
        const title = if (success) "AI Response Ready" else "AI Request Failed";
        const body = if (success)
            "Your AI assistant has finished processing your request"
        else
            "The AI request encountered an error";

        try self.sendCategorizedNotification(
            title,
            body,
            if (success) .normal else .critical,
            if (success) .ai_response else .error,
        );
    }

    /// Notify about command completion
    pub fn notifyCommandComplete(
        self: *NotificationManager,
        command: []const u8,
        exit_code: i32,
        duration_ms: i64,
    ) !void {
        const success = exit_code == 0;
        const title = if (success) "Command Completed" else "Command Failed";

        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "'{s}' {s} ({d}ms)", .{
            if (command.len > 50) command[0..50] else command,
            if (success) "succeeded" else "failed",
            duration_ms,
        }) catch "Command finished";

        try self.sendCategorizedNotification(
            title,
            body,
            if (success) .normal else .critical,
            .command_complete,
        );
    }

    /// Notify about long-running command
    pub fn notifyLongCommand(
        self: *NotificationManager,
        command: []const u8,
        duration_ms: i64,
    ) !void {
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "'{s}' has been running for {d}ms", .{
            if (command.len > 50) command[0..50] else command,
            duration_ms,
        }) catch "Command running";

        try self.sendCategorizedNotification(
            "Long-Running Command",
            body,
            .low,
            .workflow_progress,
        );
    }

    /// Notify about workflow progress
    pub fn notifyWorkflowProgress(
        self: *NotificationManager,
        workflow_name: []const u8,
        current_step: usize,
        total_steps: usize,
    ) !void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "Step {d}/{d} completed", .{
            current_step,
            total_steps,
        }) catch "Progress update";

        try self.sendCategorizedNotification(
            workflow_name,
            body,
            .low,
            .workflow_progress,
        );
    }

    /// Set terminal focus state
    pub fn setTerminalFocused(self: *NotificationManager, focused: bool) void {
        self.is_terminal_focused = focused;
    }

    /// Enable or disable notifications
    pub fn setEnabled(self: *NotificationManager, enabled: bool) void {
        self.config.enabled = enabled;
    }

    /// Enable or disable sounds
    pub fn setSoundsEnabled(self: *NotificationManager, enabled: bool) void {
        self.config.sounds_enabled = enabled;
    }

    /// Set do not disturb mode
    pub fn setDoNotDisturb(self: *NotificationManager, dnd: bool) void {
        self.config.do_not_disturb = dnd;
    }

    /// Set action callback
    pub fn setActionCallback(
        self: *NotificationManager,
        callback: *const fn ([]const u8, []const u8, ?*anyopaque) void,
        user_data: ?*anyopaque,
    ) void {
        self.on_action = callback;
        self.callback_user_data = user_data;
    }

    /// Get notification history
    pub fn getHistory(self: *const NotificationManager, limit: usize) []const NotificationHistoryEntry {
        const start = if (self.history.items.len > limit)
            self.history.items.len - limit
        else
            0;
        return self.history.items[start..];
    }

    /// Clear notification history
    pub fn clearHistory(self: *NotificationManager) void {
        for (self.history.items) |*entry| {
            entry.notification.deinit(self.alloc);
        }
        self.history.clearRetainingCapacity();
    }

    /// Check if notifications are available on this platform
    pub fn isAvailable() bool {
        return switch (builtin.os.tag) {
            .macos, .linux => true,
            else => false, // Fallback is always available
        };
    }
};

test "NotificationManager basic operations" {
    const alloc = std.testing.allocator;

    var manager = NotificationManager.init(alloc);
    defer manager.deinit();

    // Test that manager initializes correctly
    try std.testing.expect(manager.config.enabled);
    try std.testing.expect(manager.is_terminal_focused);

    // Test configuration
    manager.setEnabled(false);
    try std.testing.expect(!manager.config.enabled);

    manager.setDoNotDisturb(true);
    try std.testing.expect(manager.config.do_not_disturb);
}

test "Notification creation" {
    const alloc = std.testing.allocator;

    var notif = try Notification.init(alloc, "Test Title", "Test Body");
    defer notif.deinit(alloc);

    try std.testing.expectEqualStrings("Test Title", notif.title);
    try std.testing.expectEqualStrings("Test Body", notif.body);
    try std.testing.expectEqual(Urgency.normal, notif.urgency);
}
