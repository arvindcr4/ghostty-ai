//! WebGL sampler management
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../../renderer.zig");

/// A WebGL sampler defines how textures are sampled
pub const Sampler = @This();

/// The allocator for this sampler
alloc: Allocator,

/// Sampler options
opts: rendererpkg.SamplerOptions,

/// WebGL sampler ID
id: u32,

pub fn init(alloc: Allocator, opts: rendererpkg.SamplerOptions) !Sampler {
    return .{
        .alloc = alloc,
        .opts = opts,
        .id = 0, // TODO: Create WebGL sampler
    };
}

pub fn deinit(self: *Sampler) void {
    // TODO: Delete WebGL sampler
    _ = self;
}

test {
    _ = Sampler;
}
