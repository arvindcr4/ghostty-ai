//! Session Sharing Module
//!
//! This module provides collaborative terminal session sharing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const log = std.log.scoped(.ai_session_sharing);

/// A shared session
pub const SharedSession = struct {
    id: []const u8,
    name: []const u8,
    owner: []const u8,
    participants: ArrayList([]const u8),
    read_only: bool,
    created_at: i64,

    pub fn deinit(self: *SharedSession, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.name);
        alloc.free(self.owner);
        for (self.participants.items) |p| alloc.free(p);
        self.participants.deinit();
    }
};

/// Session Sharing Manager
pub const SessionSharingManager = struct {
    alloc: Allocator,
    sessions: ArrayList(*SharedSession),
    enabled: bool,

    /// Initialize session sharing manager
    pub fn init(alloc: Allocator) SessionSharingManager {
        return .{
            .alloc = alloc,
            .sessions = ArrayList(*SharedSession).init(alloc),
            .enabled = true,
        };
    }

    pub fn deinit(self: *SessionSharingManager) void {
        for (self.sessions.items) |session| {
            session.deinit(self.alloc);
            self.alloc.destroy(session);
        }
        self.sessions.deinit();
    }

    /// Create a shared session
    pub fn createSession(
        self: *SessionSharingManager,
        name: []const u8,
        owner: []const u8,
        read_only: bool,
    ) !*SharedSession {
        const id = try std.fmt.allocPrint(self.alloc, "session_{d}", .{std.time.timestamp()});
        const session = try self.alloc.create(SharedSession);
        session.* = .{
            .id = id,
            .name = try self.alloc.dupe(u8, name),
            .owner = try self.alloc.dupe(u8, owner),
            .participants = ArrayList([]const u8).init(self.alloc),
            .read_only = read_only,
            .created_at = std.time.timestamp(),
        };

        try self.sessions.append(session);
        return session;
    }

    /// Generate share URL
    pub fn getShareUrl(self: *const SessionSharingManager, session: *const SharedSession) ![]const u8 {
        return try std.fmt.allocPrint(
            self.alloc,
            "ghostty://session/{s}",
            .{session.id},
        );
    }
    
    /// Add participant to session
    pub fn addParticipant(
        self: *SessionSharingManager,
        session: *SharedSession,
        participant_id: []const u8,
    ) !void {
        try session.participants.append(try self.alloc.dupe(u8, participant_id));
    }
    
    /// Remove participant from session
    pub fn removeParticipant(
        self: *SessionSharingManager,
        session: *SharedSession,
        participant_id: []const u8,
    ) void {
        for (session.participants.items, 0..) |pid, i| {
            if (std.mem.eql(u8, pid, participant_id)) {
                self.alloc.free(pid);
                _ = session.participants.swapRemove(i);
                break;
            }
        }
    }
    
    /// Get session by ID
    pub fn getSession(self: *const SessionSharingManager, session_id: []const u8) ?*SharedSession {
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.id, session_id)) {
                return session;
            }
        }
        return null;
    }
    
    /// Delete a session
    pub fn deleteSession(self: *SessionSharingManager, session_id: []const u8) void {
        for (self.sessions.items, 0..) |session, i| {
            if (std.mem.eql(u8, session.id, session_id)) {
                session.deinit(self.alloc);
                self.alloc.destroy(session);
                _ = self.sessions.swapRemove(i);
                break;
            }
        }
    }
};
