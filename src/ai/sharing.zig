//! Block Sharing Module
//!
//! This module provides permalink sharing of command blocks and workflows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const json = std.json;

const log = std.log.scoped(.ai_sharing);

/// A shareable block
pub const ShareableBlock = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    block_type: BlockType,
    created_at: i64,
    share_token: []const u8,
    public: bool,

    pub const BlockType = enum {
        command_block,
        workflow,
        notebook,
        conversation,
    };

    pub fn deinit(self: *ShareableBlock, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.title);
        alloc.free(self.content);
        alloc.free(self.share_token);
    }

    /// Generate a share token
    pub fn generateToken(alloc: Allocator) ![]const u8 {
        var rng = std.rand.DefaultPrng.init(@intCast(std.time.timestamp()));
        var token_buf: [32]u8 = undefined;
        const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

        for (&token_buf) |*byte| {
            byte.* = alphabet[rng.random().intRangeLessThan(usize, 0, alphabet.len)];
        }

        return try alloc.dupe(u8, &token_buf);
    }
};

/// Sharing Manager
pub const SharingManager = struct {
    alloc: Allocator,
    blocks: std.StringHashMap(*ShareableBlock),
    base_url: []const u8,

    /// Initialize sharing manager
    pub fn init(alloc: Allocator, base_url: []const u8) SharingManager {
        return .{
            .alloc = alloc,
            .blocks = std.StringHashMap(*ShareableBlock).init(alloc),
            .base_url = base_url,
        };
    }

    pub fn deinit(self: *SharingManager) void {
        var iter = self.blocks.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.blocks.deinit();
        self.alloc.free(self.base_url);
    }

    /// Share a block
    pub fn shareBlock(
        self: *SharingManager,
        title: []const u8,
        content: []const u8,
        block_type: ShareableBlock.BlockType,
        public: bool,
    ) !*ShareableBlock {
        const id = try std.fmt.allocPrint(self.alloc, "share_{d}", .{std.time.timestamp()});
        const token = try ShareableBlock.generateToken(self.alloc);

        const block = try self.alloc.create(ShareableBlock);
        block.* = .{
            .id = id,
            .title = try self.alloc.dupe(u8, title),
            .content = try self.alloc.dupe(u8, content),
            .block_type = block_type,
            .created_at = std.time.timestamp(),
            .share_token = token,
            .public = public,
        };

        try self.blocks.put(id, block);
        return block;
    }

    /// Get shareable URL
    pub fn getShareUrl(self: *const SharingManager, block: *const ShareableBlock) ![]const u8 {
        return try std.fmt.allocPrint(
            self.alloc,
            "{s}/share/{s}",
            .{ self.base_url, block.share_token },
        );
    }

    /// Get block by token
    pub fn getBlockByToken(self: *const SharingManager, token: []const u8) ?*ShareableBlock {
        var iter = self.blocks.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*.share_token, token)) {
                return entry.value_ptr.*;
            }
        }
        return null;
    }
};
