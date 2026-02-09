const config = @import("config");

pub usingnamespace @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", {});
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");

    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");

    @cInclude("xkbcommon/xkbcommon.h");

    // TODO: Need to do it like this for zls
    //if (config.backends.x11)
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xkb.h");

    if (config.backends.wayland)
        @cInclude("wayland-client.h");

    if (config.backends.drm) {
        @cInclude("xf86drm.h");
        @cInclude("xf86drmMode.h");
        @cInclude("drm_mode.h");
        @cInclude("drm_fourcc.h");
        @cInclude("gbm.h");
    }

    @cDefine("_GNU_SOURCE", {});
    @cDefine("__USE_GNU", {});
    @cInclude("sys/shm.h");
    @cInclude("sys/socket.h");
});

pub const KeySym = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));
