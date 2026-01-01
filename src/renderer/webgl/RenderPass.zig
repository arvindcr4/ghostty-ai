//! WebGL render pass
const std = @import("std");
const Allocator = std.mem.Allocator;
const rendererpkg = @import("../../renderer.zig");
const Frame = @import("Frame.zig");
const Pipeline = @import("Pipeline.zig");

/// A render pass represents a set of drawing operations with a specific pipeline
pub const RenderPass = @This();

/// The allocator for this pass
alloc: Allocator,

/// The frame this pass belongs to
frame: *Frame,

/// The pipeline to use for this pass
pipeline: Pipeline,

/// Uniform values for this pass
uniforms: std.ArrayList(Uniform),

/// Vertex buffer (if any)
vertex_buffer: ?Buffer = null,

/// Index buffer (if any)
index_buffer: ?Buffer = null,

/// Number of vertices to draw
vertex_count: u32 = 0,

/// Uniform value types
pub const Uniform = struct {
    /// Uniform location in the shader
    location: i32,

    /// Uniform value
    value: rendererpkg.UniformValue,
};

/// Buffer reference
pub const Buffer = struct {
    /// WebGL buffer ID
    id: u32,

    /// Buffer size in bytes
    size: usize,
};

pub fn init(alloc: Allocator, frame: *Frame, pipeline: Pipeline) !RenderPass {
    return .{
        .alloc = alloc,
        .frame = frame,
        .pipeline = pipeline,
        .uniforms = std.ArrayList(Uniform).init(alloc),
    };
}

pub fn deinit(self: *RenderPass) void {
    self.uniforms.deinit();
}

/// Set a uniform value
pub fn uniformSet(self: *RenderPass, location: i32, value: rendererpkg.UniformValue) !void {
    const uniform = Uniform{
        .location = location,
        .value = value,
    };
    try self.uniforms.append(uniform);
}

/// Set vertex buffer
pub fn vertexBufferSet(self: *RenderPass, buffer: Buffer, vertex_count: u32) void {
    self.vertex_buffer = buffer;
    self.vertex_count = vertex_count;
}

/// Set index buffer
pub fn indexBufferSet(self: *RenderPass, buffer: Buffer) void {
    self.index_buffer = buffer;
}

test {
    _ = RenderPass;
}
