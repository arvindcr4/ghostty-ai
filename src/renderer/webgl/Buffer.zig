//! WebGL buffer management
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../../renderer.zig");

/// A WebGL buffer represents GPU memory for vertex/index data
pub const Buffer = @This();

/// The allocator for this buffer
alloc: Allocator,

/// Buffer usage hint
usage: Usage,

/// WebGL buffer ID
id: u32,

/// Buffer size in bytes
size: usize,

/// Buffer usage types
pub const Usage = enum {
    vertex,
    index,
    uniform,
};

pub fn init(alloc: Allocator, data: []const u8, usage: Usage) !Buffer {
    // TODO: Upload data to GPU
    return .{
        .alloc = alloc,
        .usage = usage,
        .id = 0, // TODO: Create WebGL buffer
        .size = data.len,
    };
}

pub fn deinit(self: *Buffer) void {
    // TODO: Delete WebGL buffer
    _ = self;
}

/// Update buffer data
pub fn update(self: *Buffer, data: []const u8) !void {
    // TODO: Update WebGL buffer data
    self.size = data.len;
}

test {
    _ = Buffer;
}
