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
    \\#define MAX_GRADIENT_STOPS 16
    \\#define GRADIENT_KIND_NONE 0
    \\#define GRADIENT_KIND_RADIAL 1
    \\#define GRADIENT_KIND_LINEAR 2
    \\#define GRADIENT_KIND_CONICAL 3
    \\uniform sampler2D u_src;
    \\uniform sampler2D u_src_alpha_map;
    \\uniform bool u_use_src_alpha_map;
    \\uniform vec4 u_src_alpha_swizzle;
    \\uniform bool u_src_is_solid;
    \\uniform vec4 u_src_solid_color;
    \\uniform int u_src_gradient_kind;
    \\uniform int u_src_gradient_num_stops;
    \\uniform float u_src_gradient_stops[MAX_GRADIENT_STOPS];
    \\uniform vec4 u_src_gradient_colors[MAX_GRADIENT_STOPS];
    \\uniform vec2 u_src_radial_inner_center;
    \\uniform vec2 u_src_radial_outer_center;
    \\uniform float u_src_radial_inner_radius;
    \\uniform float u_src_radial_outer_radius;
    \\uniform vec2 u_src_linear_p1;
    \\uniform vec2 u_src_linear_p2;
    \\uniform vec2 u_src_conical_center;
    \\uniform float u_src_conical_angle;
    \\
    \\uniform sampler2D u_mask;
    \\uniform bool u_use_mask;
    \\uniform bool u_component_alpha;
    \\uniform vec4 u_mask_swizzle;
    \\uniform sampler2D u_mask_alpha_map;
    \\uniform bool u_use_mask_alpha_map;
    \\uniform vec4 u_mask_alpha_swizzle;
    \\uniform bool u_mask_is_solid;
    \\uniform vec4 u_mask_solid_color;
    \\
    \\uniform sampler2D u_clip_mask;
    \\uniform bool u_use_clip_mask;
    \\uniform vec4 u_clip_swizzle;
    \\uniform bool u_dst_is_alpha_only;
    \\
    \\// Pick a color for parameter t (in [0, 1]) by linearly interpolating
    \\// between the surrounding stops. Stops are assumed pre-sorted ascending.
    \\vec4 sample_gradient_stops(float t) {
    \\    if (t <= u_src_gradient_stops[0]) return u_src_gradient_colors[0];
    \\    for (int i = 0; i < MAX_GRADIENT_STOPS - 1; i++) {
    \\        if (i + 1 >= u_src_gradient_num_stops) break;
    \\        if (t <= u_src_gradient_stops[i + 1]) {
    \\            float span = u_src_gradient_stops[i + 1] - u_src_gradient_stops[i];
    \\            float seg_t = span > 0.0 ? (t - u_src_gradient_stops[i]) / span : 0.0;
    \\            return mix(u_src_gradient_colors[i], u_src_gradient_colors[i + 1], seg_t);
    \\        }
    \\    }
    \\    return u_src_gradient_colors[u_src_gradient_num_stops - 1];
    \\}
    \\
    \\vec4 sample_radial_gradient(vec2 p) {
    \\    // Two-circle radial gradient: find t such that
    \\    //   |p - (c0 + t*(c1-c0))|^2 == (r0 + t*(r1-r0))^2
    \\    // Solve quadratic At^2 + Bt + C = 0 and pick the root whose circle
    \\    // has non-negative radius (the geometrically meaningful one).
    \\    vec2 c0 = u_src_radial_inner_center;
    \\    vec2 c1 = u_src_radial_outer_center;
    \\    float r0 = u_src_radial_inner_radius;
    \\    float r1 = u_src_radial_outer_radius;
    \\    vec2 d = c1 - c0;
    \\    float dr = r1 - r0;
    \\    vec2 pd = p - c0;
    \\    float A = dot(d, d) - dr * dr;
    \\    float B = -2.0 * (dot(d, pd) + r0 * dr);
    \\    float C = dot(pd, pd) - r0 * r0;
    \\    float t;
    \\    if (abs(A) < 1e-6) {
    \\        if (abs(B) < 1e-6) return vec4(0.0);
    \\        t = -C / B;
    \\    } else {
    \\        float disc = B * B - 4.0 * A * C;
    \\        if (disc < 0.0) return vec4(0.0);
    \\        float sq = sqrt(disc);
    \\        float t_plus = (-B + sq) / (2.0 * A);
    \\        float t_minus = (-B - sq) / (2.0 * A);
    \\        if (r0 + t_plus * dr >= 0.0) {
    \\            t = t_plus;
    \\        } else if (r0 + t_minus * dr >= 0.0) {
    \\            t = t_minus;
    \\        } else {
    \\            return vec4(0.0);
    \\        }
    \\    }
    \\    return sample_gradient_stops(clamp(t, 0.0, 1.0));
    \\}
    \\
    \\vec4 sample_linear_gradient(vec2 p) {
    \\    // Project p onto the gradient axis (p1, p2). t = 0 at p1, 1 at p2.
    \\    vec2 d = u_src_linear_p2 - u_src_linear_p1;
    \\    float denom = dot(d, d);
    \\    if (denom < 1e-6) return u_src_gradient_colors[0];
    \\    float t = dot(p - u_src_linear_p1, d) / denom;
    \\    return sample_gradient_stops(clamp(t, 0.0, 1.0));
    \\}
    \\
    \\vec4 sample_conical_gradient(vec2 p) {
    \\    // Sweep gradient: t = (atan2(dy, dx) - start_angle) / 2π, wrapped
    \\    // to [0, 1]. `u_src_conical_angle` is in radians.
    \\    vec2 rel = p - u_src_conical_center;
    \\    float a = atan(rel.y, rel.x) - u_src_conical_angle;
    \\    float t = a / (2.0 * 3.14159265358979);
    \\    t = fract(t);
    \\    if (t < 0.0) t += 1.0;
    \\    return sample_gradient_stops(t);
    \\}
    \\
    \\void main() {
    \\    vec4 src;
    \\    if (u_src_is_solid) {
    \\        src = u_src_solid_color;
    \\    } else if (u_src_gradient_kind != GRADIENT_KIND_NONE) {
    \\        // For procedural sources gl_TexCoord[0].st carries the
    \\        // un-normalized source-space pixel position (the texture-size
    \\        // divisor on that path is 1).
    \\        vec2 p = gl_TexCoord[0].st;
    \\        if (u_src_gradient_kind == GRADIENT_KIND_RADIAL) {
    \\            src = sample_radial_gradient(p);
    \\        } else if (u_src_gradient_kind == GRADIENT_KIND_LINEAR) {
    \\            src = sample_linear_gradient(p);
    \\        } else {
    \\            src = sample_conical_gradient(p);
    \\        }
    \\    } else {
    \\        src = texture2D(u_src, gl_TexCoord[0].st);
    \\        if (u_use_src_alpha_map) {
    \\            src.a = dot(texture2D(u_src_alpha_map, gl_TexCoord[1].st), u_src_alpha_swizzle);
    \\        }
    \\    }
    \\
    \\    vec4 result = src;
    \\    if (u_use_mask) {
    \\        vec4 mask;
    \\        if (u_mask_is_solid) {
    \\            mask = u_mask_solid_color;
    \\        } else {
    \\            mask = texture2D(u_mask, gl_TexCoord[2].st);
    \\            mask.a = dot(mask, u_mask_swizzle);
    \\            if (u_use_mask_alpha_map) {
    \\                mask.a = dot(texture2D(u_mask_alpha_map, gl_TexCoord[3].st), u_mask_alpha_swizzle);
    \\            }
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
    \\    if (u_dst_is_alpha_only) {
    \\        gl_FragColor = vec4(result.a, 0.0, 0.0, 0.0);
    \\    } else {
    \\        gl_FragColor = result;
    \\    }
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
