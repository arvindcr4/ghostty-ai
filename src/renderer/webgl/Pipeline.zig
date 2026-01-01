//! WebGL pipeline management
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../../renderer.zig");

/// A WebGL pipeline represents the complete state needed for rendering
pub const Pipeline = @This();

/// The allocator for this pipeline
alloc: Allocator,

/// Pipeline options
opts: rendererpkg.PipelineOptions,

/// WebGL program ID (if compiled)
program: ?u32 = null,

/// Vertex shader ID
vertex_shader: ?u32 = null,

/// Fragment shader ID
fragment_shader: ?u32 = null,

pub fn init(alloc: Allocator, opts: rendererpkg.PipelineOptions) !Pipeline {
    return .{
        .alloc = alloc,
        .opts = opts,
    };
}

pub fn deinit(self: *Pipeline) void {
    // TODO: Clean up WebGL shaders and program
    _ = self;
}

/// Compile the pipeline (create WebGL program)
pub fn compile(_: *Pipeline) !void {
    // TODO: Implement WebGL shader compilation
    // This will involve:
    // 1. Create vertex and fragment shaders
    // 2. Compile shaders
    // 3. Create program and link shaders
    // 4. Validate program
}

test {
    _ = Pipeline;
}
