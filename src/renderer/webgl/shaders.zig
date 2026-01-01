//! WebGL shader management
const std = @import("std");
const rendererpkg = @import("../../renderer.zig");

/// WebGL shader utilities and constants
pub const shaders = struct {
    /// Default vertex shader for terminal rendering
    pub const DEFAULT_VERTEX_SHADER =
        \\#version 300 es
        \\in vec2 position;
        \\in vec2 texCoord;
        \\out vec2 fragTexCoord;
        \\uniform mat4 projection;
        \\void main() {
        \\    gl_Position = projection * vec4(position, 0.0, 1.0);
        \\    fragTexCoord = texCoord;
        \\}
    ;

    /// Default fragment shader for terminal rendering
    pub const DEFAULT_FRAGMENT_SHADER =
        \\#version 300 es
        \\precision highp float;
        \\in vec2 fragTexCoord;
        \\out vec4 fragColor;
        \\uniform sampler2D tex;
        \\uniform vec4 color;
        \\void main() {
        \\    vec4 texColor = texture(tex, fragTexCoord);
        \\    fragColor = vec4(color.rgb, color.a * texColor.a);
        \\}
    ;

    /// Text rendering fragment shader
    pub const TEXT_FRAGMENT_SHADER =
        \\#version 300 es
        \\precision highp float;
        \\in vec2 fragTexCoord;
        \\out vec4 fragColor;
        \\uniform sampler2D tex;
        \\uniform vec4 fg_color;
        \\uniform vec4 bg_color;
        \\void main() {
        \\    float alpha = texture(tex, fragTexCoord).a;
        \\    fragColor = mix(bg_color, fg_color, alpha);
        \\}
    ;
};

test {
    _ = shaders;
}
