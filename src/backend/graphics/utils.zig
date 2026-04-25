const std = @import("std");
const phx = @import("../../phoenix.zig");
const c = phx.c;

pub const mask_vertex_shader_src: [*c]const u8 =
    \\#version 120
    \\void main() {
    \\    gl_TexCoord[0] = gl_MultiTexCoord0;
    \\    gl_TexCoord[1] = gl_MultiTexCoord1;
    \\    gl_TexCoord[2] = gl_MultiTexCoord2;
    \\    gl_TexCoord[3] = gl_MultiTexCoord3;
    \\    gl_TexCoord[4] = gl_MultiTexCoord4;
    \\    gl_Position = gl_ModelViewProjectionMatrix * gl_Vertex;
    \\}
;

pub const mask_fragment_shader_src: [*c]const u8 =
    \\#version 120
    \\uniform sampler2D u_src;
    \\uniform sampler2D u_src_alpha_map;
    \\uniform bool u_use_src_alpha_map;
    \\uniform vec4 u_src_alpha_swizzle;
    \\
    \\uniform sampler2D u_mask;
    \\uniform bool u_use_mask;
    \\uniform bool u_component_alpha;
    \\uniform sampler2D u_mask_alpha_map;
    \\uniform bool u_use_mask_alpha_map;
    \\uniform vec4 u_mask_alpha_swizzle;
    \\
    \\uniform sampler2D u_clip_mask;
    \\uniform bool u_use_clip_mask;
    \\uniform vec4 u_clip_swizzle;
    \\
    \\void main() {
    \\    vec4 src = texture2D(u_src, gl_TexCoord[0].st);
    \\    if (u_use_src_alpha_map) {
    \\        src.a = dot(texture2D(u_src_alpha_map, gl_TexCoord[1].st), u_src_alpha_swizzle);
    \\    }
    \\
    \\    vec4 result = src;
    \\    if (u_use_mask) {
    \\        vec4 mask = texture2D(u_mask, gl_TexCoord[2].st);
    \\        if (u_use_mask_alpha_map) {
    \\            mask.a = dot(texture2D(u_mask_alpha_map, gl_TexCoord[3].st), u_mask_alpha_swizzle);
    \\        }
    \\        if (u_component_alpha) {
    \\            result = src * mask;
    \\        } else {
    \\            result = src * mask.a;
    \\        }
    \\    }
    \\
    \\    if (u_use_clip_mask) {
    \\        float clip = dot(texture2D(u_clip_mask, gl_TexCoord[4].st), u_clip_swizzle);
    \\        if (clip < 0.5) discard;
    \\    }
    \\
    \\    gl_FragColor = result;
    \\}
;

pub fn create_shader_program(vertex_shader_src: [*c]const u8, fragment_shader_src: [*c]const u8) !c.GLuint {
    const vs = try compile_shader(c.GL_VERTEX_SHADER, vertex_shader_src);
    defer c.glDeleteShader(vs);

    const fs = try compile_shader(c.GL_FRAGMENT_SHADER, fragment_shader_src);
    defer c.glDeleteShader(fs);

    const program = c.glCreateProgram();
    if (program == 0)
        return error.FailedToCreateProgram;
    errdefer c.glDeleteProgram(program);

    c.glAttachShader(program, vs);
    c.glAttachShader(program, fs);
    c.glLinkProgram(program);

    var status: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &status);
    if (status == c.GL_FALSE) {
        var log_buf: [1024]u8 = undefined;
        var log_len: c.GLsizei = 0;
        c.glGetProgramInfoLog(program, log_buf.len, &log_len, &log_buf);
        std.log.err("OpenGL program link failed, error: {s}", .{log_buf[0..@intCast(log_len)]});
        return error.ProgramLinkFailed;
    }
    return program;
}

fn compile_shader(shader_type: c.GLenum, source: [*c]const u8) !c.GLuint {
    const shader = c.glCreateShader(shader_type);
    if (shader == 0)
        return error.FailedToCreateShader;
    errdefer c.glDeleteShader(shader);

    c.glShaderSource(shader, 1, &source, null);
    c.glCompileShader(shader);

    var status: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &status);
    if (status == c.GL_FALSE) {
        var log_buf: [1024]u8 = undefined;
        var log_len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, log_buf.len, &log_len, &log_buf);
        std.log.err("GraphicsEgl: shader compile failed: {s}", .{log_buf[0..@intCast(log_len)]});
        return error.ShaderCompileFailed;
    }
    return shader;
}
