//! Graphics API wrapper for WebGL 2.0 in the browser.
const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(WebGL);

const log = std.log.scoped(.webgl);

/// WebGL-specific C API for JavaScript interop
pub const CAPI = struct {
    /// Initialize WebGL context
    extern fn ghostty_js_webgl_init(canvas_id: [*c]const u8, width: u32, height: u32) ?*anyopaque;

    /// Resize WebGL context
    extern fn ghostty_js_webgl_resize(ctx: *anyopaque, width: u32, height: u32) void;

    /// Clear screen with color
    extern fn ghostty_js_webgl_clear(ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) void;

    /// Present frame (swap buffers equivalent)
    extern fn ghostty_js_webgl_present(ctx: *anyopaque) void;

    /// Cleanup WebGL context
    extern fn ghostty_js_webgl_deinit(ctx: *anyopaque) void;
};

pub const WebGL = @This();

pub const GraphicsAPI = WebGL;
pub const Target = @import("webgl/Target.zig");
pub const Frame = @import("webgl/Frame.zig");
pub const RenderPass = @import("webgl/RenderPass.zig");
pub const Pipeline = @import("webgl/Pipeline.zig");
pub const Buffer = @import("webgl/Buffer.zig");
pub const Sampler = @import("webgl/Sampler.zig");
pub const Texture = @import("webgl/Texture.zig");
pub const shaders = @import("webgl/shaders.zig");

/// We require WebGL 2.0
pub const MIN_VERSION_MAJOR = 2;
pub const MIN_VERSION_MINOR = 0;

/// Because WebGL doesn't have swap chains, we use single buffering
pub const swap_chain_count = 1;

/// Because WebGL's frame completion is always sync, we have no need for multi-buffering
pub const custom_shader_y_is_down = false;
pub const custom_shader_target = rendererpkg.shadertoy.Target.glsl;

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// WebGL rendering context
ctx: ?*anyopaque = null,

/// Screen dimensions
width: u32 = 0,
height: u32 = 0,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!WebGL {
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *WebGL) void {
    if (self.ctx) |ctx| {
        CAPI.ghostty_js_webgl_deinit(ctx);
        self.ctx = null;
    }
}

/// Initialize WebGL for a surface
pub fn surfaceInit(self: *WebGL, surface: *apprt.Surface) !void {
    _ = surface; // TODO: Get canvas ID from surface
    const canvas_id = "ghostty-canvas";

    // Initialize WebGL context via JavaScript
    self.ctx = CAPI.ghostty_js_webgl_init(canvas_id.ptr, self.width, self.height);
    if (self.ctx == null) {
        return error.WebGLContextCreationFailed;
    }

    log.info("WebGL context initialized: {}x{}", .{ self.width, self.height });
}

/// Present the rendered frame
pub fn present(self: *WebGL, _: Target) !void {
    if (self.ctx) |ctx| {
        CAPI.ghostty_js_webgl_present(ctx);
    }
}

/// Create a target for rendering
pub fn targetCreate(
    self: *WebGL,
    size: rendererpkg.Size,
    scale: apprt.ContentScale,
) !Target {
    self.width = size.width;
    self.height = size.height;

    // Update viewport through JavaScript
    // TODO: Implement viewport update via CAPI

    return Target.init(self.alloc, size, scale);
}

/// Set the current target
pub fn targetSet(self: *WebGL, target: Target) void {
    _ = self;
    _ = target;
    // WebGL doesn't need explicit target setting like OpenGL framebuffers
}

/// Clear the target
pub fn targetClear(self: *WebGL, target: Target, color: rendererpkg.Color) void {
    _ = target;
    if (self.ctx) |ctx| {
        CAPI.ghostty_js_webgl_clear(ctx, @as(f32, @floatFromInt(color.r)) / 255.0, @as(f32, @floatFromInt(color.g)) / 255.0, @as(f32, @floatFromInt(color.b)) / 255.0, @as(f32, @floatFromInt(color.a)) / 255.0);
    }
}

/// Create a frame for rendering
pub fn frameCreate(self: *WebGL, target: Target) !Frame {
    return Frame.init(self.alloc, target);
}

/// Submit a frame for presentation
pub fn frameSubmit(self: *WebGL, frame: Frame) !void {
    defer frame.deinit();

    // Execute all render passes
    for (frame.passes.items) |pass| {
        try self.renderPass(pass);
    }

    // Present the frame
    try self.present(frame.target);
}

/// Create a render pass
pub fn renderPassCreate(
    self: *WebGL,
    frame: *Frame,
    pipeline: Pipeline,
) !RenderPass {
    return RenderPass.init(self.alloc, frame, pipeline);
}

/// Execute a render pass
fn renderPass(_: *WebGL, pass: RenderPass) !void {
    // TODO: Implement WebGL render pass execution
    // This will involve setting up shaders, uniforms, and draw calls
    _ = pass;
}

/// Set a uniform value
pub fn uniformSet(_: *WebGL, uniform: RenderPass.Uniform) !void {
    // TODO: Implement WebGL uniform setting
    _ = uniform;
}

/// Create a pipeline
pub fn pipelineCreate(self: *WebGL, opts: rendererpkg.PipelineOptions) !Pipeline {
    return Pipeline.init(self.alloc, opts);
}

/// Create a buffer
pub fn bufferCreate(self: *WebGL, data: []const u8, usage: Buffer.Usage) !Buffer {
    return Buffer.init(self.alloc, data, usage);
}

/// Create a texture
pub fn textureCreate(self: *WebGL, opts: rendererpkg.TextureOptions) !Texture {
    return Texture.init(self.alloc, opts);
}

/// Create a sampler
pub fn samplerCreate(self: *WebGL, opts: rendererpkg.SamplerOptions) !Sampler {
    return Sampler.init(self.alloc, opts);
}

/// Get renderer health status
pub fn health(self: *WebGL) rendererpkg.Health {
    if (self.ctx == null) return .unhealthy;
    return .healthy;
}

/// Get renderer information
pub fn info(_: *WebGL) rendererpkg.Info {
    return .{
        .backend = .webgl,
        .version = "2.0",
    };
}

/// Get renderer capabilities
pub fn capabilities(self: *WebGL) rendererpkg.Capabilities {
    _ = self;
    return .{
        .custom_shaders = true,
        .hdr = false,
        .synchronized_present = true,
    };
}

test {
    _ = WebGL;
}
