//! WebGL rendering target
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../../renderer.zig");
const apprt = @import("../../apprt.zig");

/// A rendering target represents a surface that can be rendered to.
/// For WebGL, this maps to a canvas element.
pub const Target = @This();

/// The allocator used for this target
alloc: Allocator,

/// The size of the target in pixels
size: rendererpkg.Size,

/// The content scale factor (DPI)
scale: apprt.ContentScale,

pub fn init(alloc: Allocator, size: rendererpkg.Size, scale: apprt.ContentScale) Target {
    return .{
        .alloc = alloc,
        .size = size,
        .scale = scale,
    };
}

pub fn deinit(self: *Target) void {
    _ = self;
    // WebGL targets don't need explicit cleanup
}

/// Get the size of the target
pub fn getSize(self: *const Target) rendererpkg.Size {
    return self.size;
}

/// Get the content scale of the target
pub fn getScale(self: *const Target) apprt.ContentScale {
    return self.scale;
}

test {
    _ = Target;
}
