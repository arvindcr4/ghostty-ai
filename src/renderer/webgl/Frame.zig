//! WebGL rendering frame
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../../renderer.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");

/// A frame represents a complete set of rendering operations for a single frame
pub const Frame = @This();

/// The allocator for this frame
alloc: Allocator,

/// The target this frame is rendering to
target: Target,

/// The render passes in this frame
passes: std.ArrayList(RenderPass),

pub fn init(alloc: Allocator, target: Target) !Frame {
    return .{
        .alloc = alloc,
        .target = target,
        .passes = std.ArrayList(RenderPass).init(alloc),
    };
}

pub fn deinit(self: *Frame) void {
    // Deinit all passes
    for (self.passes.items) |*pass| {
        pass.deinit();
    }
    self.passes.deinit();
}

/// Create a render pass for this frame
pub fn renderPassCreate(self: *Frame, pipeline: rendererpkg.Pipeline) !*RenderPass {
    const pass = try self.alloc.create(RenderPass);
    errdefer self.alloc.destroy(pass);

    pass.* = try RenderPass.init(self.alloc, self, pipeline);
    try self.passes.append(pass.*);

    return pass;
}

test {
    _ = Frame;
}
