//! Team Collaboration Module
//!
//! This module provides multi-user collaboration features for terminal sessions.
//!
//! Features:
//! - Team member management with roles and permissions
//! - Real-time presence and activity tracking
//! - Session rooms for collaborative work
//! - Activity streams and event broadcasting
//! - Conflict resolution for concurrent edits
//! - Message passing between team members
//! - Cursor/selection sharing for pair programming

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringHashMap = std.StringHashMap;

const log = std.log.scoped(.ai_collaboration);

/// A team member with presence and activity info
pub const TeamMember = struct {
    id: []const u8,
    name: []const u8,
    email: []const u8,
    avatar_url: ?[]const u8,
    role: Role,
    permissions: Permissions,
    presence: Presence,
    last_activity: i64,
    joined_at: i64,
    metadata: StringHashMap([]const u8),

    pub const Role = enum {
        owner,
        admin,
        member,
        viewer,
        guest,
    };

    pub const Permissions = struct {
        can_execute: bool = false,
        can_edit: bool = false,
        can_share: bool = false,
        can_invite: bool = false,
        can_manage_roles: bool = false,
        can_delete_sessions: bool = false,
    };

    pub const Presence = enum {
        online,
        away,
        busy,
        offline,
    };

    /// Get permissions for a given role
    pub fn permissionsForRole(role: Role) Permissions {
        return switch (role) {
            .owner => .{
                .can_execute = true,
                .can_edit = true,
                .can_share = true,
                .can_invite = true,
                .can_manage_roles = true,
                .can_delete_sessions = true,
            },
            .admin => .{
                .can_execute = true,
                .can_edit = true,
                .can_share = true,
                .can_invite = true,
                .can_manage_roles = true,
                .can_delete_sessions = false,
            },
            .member => .{
                .can_execute = true,
                .can_edit = true,
                .can_share = false,
                .can_invite = false,
                .can_manage_roles = false,
                .can_delete_sessions = false,
            },
            .viewer => .{
                .can_execute = false,
                .can_edit = false,
                .can_share = false,
                .can_invite = false,
                .can_manage_roles = false,
                .can_delete_sessions = false,
            },
            .guest => .{
                .can_execute = false,
                .can_edit = false,
                .can_share = false,
                .can_invite = false,
                .can_manage_roles = false,
                .can_delete_sessions = false,
            },
        };
    }

    pub fn deinit(self: *TeamMember, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.email);
        if (self.avatar_url) |url| alloc.free(url);
        var meta_iter = self.metadata.iterator();
        while (meta_iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.metadata.deinit();
    }
};

/// Collaboration room/session where members work together
pub const Room = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8,
    owner_id: []const u8,
    created_at: i64,
    last_activity: i64,
    members: ArrayListUnmanaged([]const u8),
    settings: RoomSettings,
    state: RoomState,
    alloc: Allocator,

    pub const RoomSettings = struct {
        max_members: u32 = 10,
        allow_guests: bool = false,
        require_approval: bool = true,
        auto_follow_mode: bool = false,
        share_clipboard: bool = false,
        share_terminal_output: bool = true,
    };

    pub const RoomState = enum {
        active,
        paused,
        archived,
    };

    pub fn deinit(self: *Room) void {
        self.alloc.free(self.id);
        self.alloc.free(self.name);
        if (self.description) |desc| self.alloc.free(desc);
        self.alloc.free(self.owner_id);
        for (self.members.items) |member_id| {
            self.alloc.free(member_id);
        }
        self.members.deinit(self.alloc);
    }
};

/// Activity event in the collaboration stream
pub const ActivityEvent = struct {
    id: []const u8,
    room_id: []const u8,
    user_id: []const u8,
    event_type: EventType,
    payload: []const u8,
    timestamp: i64,

    pub const EventType = enum {
        // Presence events
        user_joined,
        user_left,
        presence_changed,
        // Content events
        command_executed,
        output_received,
        file_changed,
        cursor_moved,
        selection_changed,
        // Collaboration events
        message_sent,
        reaction_added,
        annotation_created,
        suggestion_made,
        // Room events
        room_settings_changed,
        member_role_changed,
    };

    pub fn deinit(self: *ActivityEvent, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.room_id);
        alloc.free(self.user_id);
        alloc.free(self.payload);
    }
};

/// Cursor position shared between collaborators
pub const SharedCursor = struct {
    user_id: []const u8,
    room_id: []const u8,
    line: u32,
    column: u32,
    selection_start: ?Position = null,
    selection_end: ?Position = null,
    color: []const u8,
    last_updated: i64,

    pub const Position = struct {
        line: u32,
        column: u32,
    };
};

/// Message between team members
pub const Message = struct {
    id: []const u8,
    room_id: []const u8,
    sender_id: []const u8,
    content: []const u8,
    message_type: MessageType,
    timestamp: i64,
    reactions: ArrayListUnmanaged(Reaction),
    reply_to: ?[]const u8,
    alloc: Allocator,

    pub const MessageType = enum {
        text,
        code_snippet,
        command_suggestion,
        file_reference,
        system_notification,
    };

    pub const Reaction = struct {
        emoji: []const u8,
        user_id: []const u8,
    };

    pub fn deinit(self: *Message) void {
        self.alloc.free(self.id);
        self.alloc.free(self.room_id);
        self.alloc.free(self.sender_id);
        self.alloc.free(self.content);
        for (self.reactions.items) |r| {
            self.alloc.free(r.emoji);
            self.alloc.free(r.user_id);
        }
        self.reactions.deinit(self.alloc);
        if (self.reply_to) |rt| self.alloc.free(rt);
    }
};

/// Sync state for conflict resolution
pub const SyncState = struct {
    version: u64,
    last_sync: i64,
    pending_changes: ArrayListUnmanaged(PendingChange),
    conflicts: ArrayListUnmanaged(Conflict),

    pub const PendingChange = struct {
        id: []const u8,
        operation: Operation,
        data: []const u8,
        timestamp: i64,
    };

    pub const Operation = enum {
        insert,
        delete,
        update,
        move,
    };

    pub const Conflict = struct {
        id: []const u8,
        local_change: []const u8,
        remote_change: []const u8,
        resolution: ?Resolution,
    };

    pub const Resolution = enum {
        accept_local,
        accept_remote,
        merge,
        manual,
    };
};

/// Configuration for collaboration features
pub const CollaborationConfig = struct {
    sync_interval_ms: u64 = 1000,
    presence_timeout_ms: u64 = 30000,
    max_activity_history: u32 = 1000,
    enable_cursor_sharing: bool = true,
    enable_output_sharing: bool = true,
    enable_clipboard_sync: bool = false,
    websocket_url: ?[]const u8 = null,
};

/// Event callback for collaboration events
pub const EventCallback = *const fn (event: *const ActivityEvent, user_data: ?*anyopaque) void;

/// Team Collaboration Manager
pub const CollaborationManager = struct {
    alloc: Allocator,
    config: CollaborationConfig,
    members: StringHashMap(*TeamMember),
    rooms: StringHashMap(*Room),
    activities: ArrayListUnmanaged(*ActivityEvent),
    messages: StringHashMap(ArrayListUnmanaged(*Message)),
    cursors: StringHashMap(*SharedCursor),
    sync_state: SyncState,
    event_callbacks: ArrayListUnmanaged(CallbackEntry),
    current_user_id: ?[]const u8,
    enabled: bool,

    const CallbackEntry = struct {
        callback: EventCallback,
        user_data: ?*anyopaque,
        event_filter: ?ActivityEvent.EventType,
    };

    /// Initialize collaboration manager
    pub fn init(alloc: Allocator) CollaborationManager {
        return initWithConfig(alloc, .{});
    }

    /// Initialize with custom configuration
    pub fn initWithConfig(alloc: Allocator, config: CollaborationConfig) CollaborationManager {
        return .{
            .alloc = alloc,
            .config = config,
            .members = StringHashMap(*TeamMember).init(alloc),
            .rooms = StringHashMap(*Room).init(alloc),
            .activities = .empty,
            .messages = StringHashMap(ArrayListUnmanaged(*Message)).init(alloc),
            .cursors = StringHashMap(*SharedCursor).init(alloc),
            .sync_state = .{
                .version = 0,
                .last_sync = 0,
                .pending_changes = .empty,
                .conflicts = .empty,
            },
            .event_callbacks = .empty,
            .current_user_id = null,
            .enabled = true,
        };
    }

    pub fn deinit(self: *CollaborationManager) void {
        // Clean up members
        var member_iter = self.members.iterator();
        while (member_iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.members.deinit();

        // Clean up rooms
        var room_iter = self.rooms.iterator();
        while (room_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.rooms.deinit();

        // Clean up activities
        for (self.activities.items) |activity| {
            activity.deinit(self.alloc);
            self.alloc.destroy(activity);
        }
        self.activities.deinit(self.alloc);

        // Clean up messages
        var msg_iter = self.messages.iterator();
        while (msg_iter.next()) |entry| {
            for (entry.value_ptr.items) |msg| {
                msg.deinit();
                self.alloc.destroy(msg);
            }
            entry.value_ptr.deinit(self.alloc);
        }
        self.messages.deinit();

        // Clean up cursors
        var cursor_iter = self.cursors.iterator();
        while (cursor_iter.next()) |entry| {
            // Free the key (user_id:room_id format)
            self.alloc.free(entry.key_ptr.*);
            // Free the cursor data
            self.alloc.free(entry.value_ptr.*.user_id);
            self.alloc.free(entry.value_ptr.*.room_id);
            self.alloc.free(entry.value_ptr.*.color);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.cursors.deinit();

        // Clean up sync state
        for (self.sync_state.pending_changes.items) |change| {
            self.alloc.free(change.id);
            self.alloc.free(change.data);
        }
        self.sync_state.pending_changes.deinit(self.alloc);

        for (self.sync_state.conflicts.items) |conflict| {
            self.alloc.free(conflict.id);
            self.alloc.free(conflict.local_change);
            self.alloc.free(conflict.remote_change);
        }
        self.sync_state.conflicts.deinit(self.alloc);

        self.event_callbacks.deinit(self.alloc);

        if (self.current_user_id) |uid| self.alloc.free(uid);
    }

    /// Set the current user (the local user)
    pub fn setCurrentUser(self: *CollaborationManager, user_id: []const u8) !void {
        if (self.current_user_id) |old_id| {
            self.alloc.free(old_id);
        }
        self.current_user_id = try self.alloc.dupe(u8, user_id);
    }

    /// Add a team member
    pub fn addMember(
        self: *CollaborationManager,
        id: []const u8,
        name: []const u8,
        email: []const u8,
        role: TeamMember.Role,
    ) !*TeamMember {
        const member = try self.alloc.create(TeamMember);
        errdefer self.alloc.destroy(member);

        const now = std.time.timestamp();
        member.* = .{
            .id = try self.alloc.dupe(u8, id),
            .name = try self.alloc.dupe(u8, name),
            .email = try self.alloc.dupe(u8, email),
            .avatar_url = null,
            .role = role,
            .permissions = TeamMember.permissionsForRole(role),
            .presence = .offline,
            .last_activity = now,
            .joined_at = now,
            .metadata = StringHashMap([]const u8).init(self.alloc),
        };

        try self.members.put(member.id, member);
        log.debug("Added team member: {s} ({s})", .{ name, id });
        return member;
    }

    /// Get a team member by ID
    pub fn getMember(self: *const CollaborationManager, user_id: []const u8) ?*TeamMember {
        return self.members.get(user_id);
    }

    /// Update member presence
    pub fn updatePresence(self: *CollaborationManager, user_id: []const u8, presence: TeamMember.Presence) !void {
        if (self.members.get(user_id)) |member| {
            const old_presence = member.presence;
            member.presence = presence;
            member.last_activity = std.time.timestamp();

            if (old_presence != presence) {
                try self.emitEvent(.presence_changed, user_id, "", &.{});
            }
        } else {
            return error.MemberNotFound;
        }
    }

    /// Check if user has permission
    pub fn hasPermission(
        self: *const CollaborationManager,
        user_id: []const u8,
        permission: enum { execute, edit, share, invite, manage_roles, delete_sessions },
    ) bool {
        if (self.members.get(user_id)) |member| {
            return switch (permission) {
                .execute => member.permissions.can_execute,
                .edit => member.permissions.can_edit,
                .share => member.permissions.can_share,
                .invite => member.permissions.can_invite,
                .manage_roles => member.permissions.can_manage_roles,
                .delete_sessions => member.permissions.can_delete_sessions,
            };
        }
        return false;
    }

    /// Get all team members
    pub fn getAllMembers(self: *const CollaborationManager) !ArrayListUnmanaged(*TeamMember) {
        var members: ArrayListUnmanaged(*TeamMember) = .empty;
        var iter = self.members.iterator();
        while (iter.next()) |entry| {
            try members.append(self.alloc, entry.value_ptr.*);
        }
        return members;
    }

    /// Get online members
    pub fn getOnlineMembers(self: *const CollaborationManager) !ArrayListUnmanaged(*TeamMember) {
        var members: ArrayListUnmanaged(*TeamMember) = .empty;
        var iter = self.members.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*.presence == .online or entry.value_ptr.*.presence == .busy) {
                try members.append(self.alloc, entry.value_ptr.*);
            }
        }
        return members;
    }

    /// Remove a team member
    pub fn removeMember(self: *CollaborationManager, user_id: []const u8) !void {
        if (self.members.fetchRemove(user_id)) |entry| {
            // Emit leave event
            try self.emitEvent(.user_left, user_id, "", &.{});
            entry.value.deinit(self.alloc);
            self.alloc.destroy(entry.value);
        } else {
            return error.MemberNotFound;
        }
    }

    /// Update member role
    pub fn updateMemberRole(
        self: *CollaborationManager,
        user_id: []const u8,
        new_role: TeamMember.Role,
    ) !void {
        if (self.members.get(user_id)) |member| {
            member.role = new_role;
            member.permissions = TeamMember.permissionsForRole(new_role);
            try self.emitEvent(.member_role_changed, user_id, "", &.{});
        } else {
            return error.MemberNotFound;
        }
    }

    // Room management

    /// Create a new collaboration room
    pub fn createRoom(
        self: *CollaborationManager,
        name: []const u8,
        owner_id: []const u8,
    ) !*Room {
        const room = try self.alloc.create(Room);
        errdefer self.alloc.destroy(room);

        const now = std.time.timestamp();
        const id = try self.generateId("room");

        room.* = .{
            .id = id,
            .name = try self.alloc.dupe(u8, name),
            .description = null,
            .owner_id = try self.alloc.dupe(u8, owner_id),
            .created_at = now,
            .last_activity = now,
            .members = .empty,
            .settings = .{},
            .state = .active,
            .alloc = self.alloc,
        };

        // Add owner as first member
        try room.members.append(self.alloc, try self.alloc.dupe(u8, owner_id));
        try self.rooms.put(room.id, room);

        log.debug("Created room: {s}", .{name});
        return room;
    }

    /// Join a room
    pub fn joinRoom(self: *CollaborationManager, room_id: []const u8, user_id: []const u8) !void {
        if (self.rooms.get(room_id)) |room| {
            // Check if already a member
            for (room.members.items) |member_id| {
                if (std.mem.eql(u8, member_id, user_id)) {
                    return; // Already in room
                }
            }

            // Check room capacity
            if (room.members.items.len >= room.settings.max_members) {
                return error.RoomFull;
            }

            try room.members.append(self.alloc, try self.alloc.dupe(u8, user_id));
            room.last_activity = std.time.timestamp();

            try self.emitEvent(.user_joined, user_id, room_id, &.{});
        } else {
            return error.RoomNotFound;
        }
    }

    /// Leave a room
    pub fn leaveRoom(self: *CollaborationManager, room_id: []const u8, user_id: []const u8) !void {
        if (self.rooms.get(room_id)) |room| {
            for (room.members.items, 0..) |member_id, i| {
                if (std.mem.eql(u8, member_id, user_id)) {
                    self.alloc.free(member_id);
                    _ = room.members.orderedRemove(i);
                    try self.emitEvent(.user_left, user_id, room_id, &.{});
                    return;
                }
            }
        } else {
            return error.RoomNotFound;
        }
    }

    /// Get room by ID
    pub fn getRoom(self: *const CollaborationManager, room_id: []const u8) ?*Room {
        return self.rooms.get(room_id);
    }

    // Activity and messaging

    /// Send a message to a room
    pub fn sendMessage(
        self: *CollaborationManager,
        room_id: []const u8,
        sender_id: []const u8,
        content: []const u8,
        message_type: Message.MessageType,
    ) !*Message {
        const message = try self.alloc.create(Message);
        errdefer self.alloc.destroy(message);

        const id = try self.generateId("msg");
        message.* = .{
            .id = id,
            .room_id = try self.alloc.dupe(u8, room_id),
            .sender_id = try self.alloc.dupe(u8, sender_id),
            .content = try self.alloc.dupe(u8, content),
            .message_type = message_type,
            .timestamp = std.time.timestamp(),
            .reactions = .empty,
            .reply_to = null,
            .alloc = self.alloc,
        };

        // Get or create message list for room
        const gop = try self.messages.getOrPut(room_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.alloc, message);

        try self.emitEvent(.message_sent, sender_id, room_id, content);
        return message;
    }

    /// Get messages for a room
    pub fn getRoomMessages(self: *const CollaborationManager, room_id: []const u8) ?[]const *Message {
        if (self.messages.get(room_id)) |msg_list| {
            return msg_list.items;
        }
        return null;
    }

    // Cursor sharing

    /// Update shared cursor position
    pub fn updateCursor(
        self: *CollaborationManager,
        user_id: []const u8,
        room_id: []const u8,
        line: u32,
        column: u32,
    ) !void {
        if (!self.config.enable_cursor_sharing) return;

        const key = try std.fmt.allocPrint(self.alloc, "{s}:{s}", .{ user_id, room_id });

        const gop = try self.cursors.getOrPut(key);
        if (!gop.found_existing) {
            // Key is now owned by the hashmap, don't free it
            const cursor = try self.alloc.create(SharedCursor);
            cursor.* = .{
                .user_id = try self.alloc.dupe(u8, user_id),
                .room_id = try self.alloc.dupe(u8, room_id),
                .line = line,
                .column = column,
                .color = try self.generateCursorColor(user_id),
                .last_updated = std.time.timestamp(),
            };
            gop.value_ptr.* = cursor;
        } else {
            // Key already exists, free the duplicate we just created
            self.alloc.free(key);
            gop.value_ptr.*.line = line;
            gop.value_ptr.*.column = column;
            gop.value_ptr.*.last_updated = std.time.timestamp();
        }

        try self.emitEvent(.cursor_moved, user_id, room_id, &.{});
    }

    /// Get all cursors in a room
    pub fn getRoomCursors(self: *const CollaborationManager, room_id: []const u8) !ArrayListUnmanaged(*SharedCursor) {
        var cursors: ArrayListUnmanaged(*SharedCursor) = .empty;
        var iter = self.cursors.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.room_id, room_id)) {
                try cursors.append(self.alloc, entry.value_ptr.*);
            }
        }
        return cursors;
    }

    // Sync and conflict resolution

    /// Queue a change for sync
    pub fn queueChange(
        self: *CollaborationManager,
        operation: SyncState.Operation,
        data: []const u8,
    ) !void {
        const id = try self.generateId("change");
        try self.sync_state.pending_changes.append(self.alloc, .{
            .id = id,
            .operation = operation,
            .data = try self.alloc.dupe(u8, data),
            .timestamp = std.time.timestamp(),
        });
        self.sync_state.version += 1;
    }

    /// Resolve a conflict
    pub fn resolveConflict(
        self: *CollaborationManager,
        conflict_id: []const u8,
        resolution: SyncState.Resolution,
    ) !void {
        for (self.sync_state.conflicts.items) |*conflict| {
            if (std.mem.eql(u8, conflict.id, conflict_id)) {
                conflict.resolution = resolution;
                return;
            }
        }
        return error.ConflictNotFound;
    }

    /// Get pending sync changes
    pub fn getPendingChanges(self: *const CollaborationManager) []const SyncState.PendingChange {
        return self.sync_state.pending_changes.items;
    }

    /// Get unresolved conflicts
    pub fn getConflicts(self: *const CollaborationManager) []const SyncState.Conflict {
        return self.sync_state.conflicts.items;
    }

    // Event system

    /// Register an event callback
    pub fn onEvent(
        self: *CollaborationManager,
        callback: EventCallback,
        user_data: ?*anyopaque,
        filter: ?ActivityEvent.EventType,
    ) !void {
        try self.event_callbacks.append(self.alloc, .{
            .callback = callback,
            .user_data = user_data,
            .event_filter = filter,
        });
    }

    /// Emit an event
    fn emitEvent(
        self: *CollaborationManager,
        event_type: ActivityEvent.EventType,
        user_id: []const u8,
        room_id: []const u8,
        payload: []const u8,
    ) !void {
        const event = try self.alloc.create(ActivityEvent);
        event.* = .{
            .id = try self.generateId("evt"),
            .room_id = try self.alloc.dupe(u8, room_id),
            .user_id = try self.alloc.dupe(u8, user_id),
            .event_type = event_type,
            .payload = try self.alloc.dupe(u8, payload),
            .timestamp = std.time.timestamp(),
        };

        // Add to activity stream
        try self.activities.append(self.alloc, event);

        // Trim activity history if needed
        while (self.activities.items.len > self.config.max_activity_history) {
            const old_event = self.activities.orderedRemove(0);
            old_event.deinit(self.alloc);
            self.alloc.destroy(old_event);
        }

        // Notify callbacks
        for (self.event_callbacks.items) |entry| {
            if (entry.event_filter == null or entry.event_filter == event_type) {
                entry.callback(event, entry.user_data);
            }
        }
    }

    /// Get recent activity for a room
    pub fn getRecentActivity(
        self: *const CollaborationManager,
        room_id: []const u8,
        limit: usize,
    ) !ArrayListUnmanaged(*ActivityEvent) {
        var events: ArrayListUnmanaged(*ActivityEvent) = .empty;
        var count: usize = 0;

        // Iterate backwards to get most recent
        var i = self.activities.items.len;
        while (i > 0 and count < limit) {
            i -= 1;
            const event = self.activities.items[i];
            if (std.mem.eql(u8, event.room_id, room_id)) {
                try events.append(self.alloc, event);
                count += 1;
            }
        }
        return events;
    }

    // Utility functions

    /// Generate a unique ID
    fn generateId(self: *CollaborationManager, prefix: []const u8) ![]const u8 {
        const timestamp = std.time.timestamp();
        var random_bytes: [8]u8 = undefined;

        // Simple pseudo-random based on timestamp
        const seed: u64 = @bitCast(timestamp);
        var rng = std.Random.DefaultPrng.init(seed);
        rng.fill(&random_bytes);

        // Format bytes as hex manually
        const hex_chars = "0123456789abcdef";
        var hex_str: [16]u8 = undefined;
        for (random_bytes, 0..) |byte, i| {
            hex_str[i * 2] = hex_chars[byte >> 4];
            hex_str[i * 2 + 1] = hex_chars[byte & 0x0f];
        }

        return try std.fmt.allocPrint(self.alloc, "{s}_{d}_{s}", .{
            prefix,
            timestamp,
            &hex_str,
        });
    }

    /// Generate a cursor color based on user ID
    fn generateCursorColor(self: *CollaborationManager, user_id: []const u8) ![]const u8 {
        // Generate consistent color from user ID hash
        var hash: u32 = 0;
        for (user_id) |c| {
            hash = hash *% 31 +% c;
        }

        const colors = [_][]const u8{
            "#FF6B6B", // Red
            "#4ECDC4", // Teal
            "#45B7D1", // Blue
            "#96CEB4", // Green
            "#FFEAA7", // Yellow
            "#DDA0DD", // Plum
            "#98D8C8", // Mint
            "#F7DC6F", // Gold
        };

        const index = hash % colors.len;
        return try self.alloc.dupe(u8, colors[index]);
    }

    /// Serialize collaboration state to JSON
    pub fn toJson(self: *const CollaborationManager) ![]const u8 {
        var buffer: ArrayListUnmanaged(u8) = .empty;
        const writer = buffer.writer(self.alloc);

        try writer.writeAll("{\"members\":[");

        var first = true;
        var iter = self.members.iterator();
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            const member = entry.value_ptr.*;
            try std.fmt.format(writer, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"email\":\"{s}\",\"role\":\"{s}\",\"presence\":\"{s}\"}}", .{
                member.id,
                member.name,
                member.email,
                @tagName(member.role),
                @tagName(member.presence),
            });
        }

        try writer.writeAll("],\"rooms\":[");

        first = true;
        var room_iter = self.rooms.iterator();
        while (room_iter.next()) |entry| {
            if (!first) try writer.writeAll(",");
            first = false;

            const room = entry.value_ptr.*;
            try std.fmt.format(writer, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"owner_id\":\"{s}\",\"member_count\":{d}}}", .{
                room.id,
                room.name,
                room.owner_id,
                room.members.items.len,
            });
        }

        try writer.writeAll("]}");

        return buffer.toOwnedSlice(self.alloc);
    }
};

// Tests
test "CollaborationManager basic operations" {
    const alloc = std.testing.allocator;
    var manager = CollaborationManager.init(alloc);
    defer manager.deinit();

    // Add members
    const owner = try manager.addMember("user1", "Alice", "alice@example.com", .owner);
    _ = try manager.addMember("user2", "Bob", "bob@example.com", .member);

    // Verify permissions
    try std.testing.expect(manager.hasPermission("user1", .manage_roles));
    try std.testing.expect(!manager.hasPermission("user2", .manage_roles));
    try std.testing.expect(manager.hasPermission("user2", .execute));

    // Update presence
    try manager.updatePresence("user1", .online);
    try std.testing.expectEqual(owner.presence, .online);

    // Create room
    const room = try manager.createRoom("Pair Programming", "user1");
    try std.testing.expectEqualStrings("Pair Programming", room.name);

    // Join room
    try manager.joinRoom(room.id, "user2");
    try std.testing.expectEqual(@as(usize, 2), room.members.items.len);

    // Send message
    const msg = try manager.sendMessage(room.id, "user1", "Hello team!", .text);
    try std.testing.expectEqualStrings("Hello team!", msg.content);
}

test "CollaborationManager cursor sharing" {
    const alloc = std.testing.allocator;
    var manager = CollaborationManager.initWithConfig(alloc, .{ .enable_cursor_sharing = true });
    defer manager.deinit();

    _ = try manager.addMember("user1", "Alice", "alice@example.com", .owner);
    const room = try manager.createRoom("Test Room", "user1");

    try manager.updateCursor("user1", room.id, 10, 5);

    var cursors = try manager.getRoomCursors(room.id);
    defer cursors.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 1), cursors.items.len);
    try std.testing.expectEqual(@as(u32, 10), cursors.items[0].line);
}
