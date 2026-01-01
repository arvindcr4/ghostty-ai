//! WebGL texture management
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../../renderer.zig");

/// A WebGL texture represents image data on the GPU
pub const Texture = @This();

/// The allocator for this texture
alloc: Allocator,

/// Texture options
opts: rendererpkg.TextureOptions,

/// WebGL texture ID
id: u32,

pub fn init(alloc: Allocator, opts: rendererpkg.TextureOptions) !Texture {
    return .{
        .alloc = alloc,
        .opts = opts,
        .id = 0, // TODO: Create WebGL texture
    };
}

pub fn deinit(self: *Texture) void {
    // TODO: Delete WebGL texture
    _ = self;
}

test {
    _ = Texture;
}
