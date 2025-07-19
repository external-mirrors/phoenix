const config = @import("config");

pub usingnamespace @cImport({
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");

    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    // TODO: Need to do it like this for zls
    //if (config.backends.x11)
    @cInclude("xcb/xcb.h");

    if (config.backends.wayland)
        @cInclude("wayland-client.h");

    if (config.backends.drm) {
        @cInclude("xf86drm.h");
        @cInclude("xf86drmMode.h");
        @cInclude("drm_mode.h");
        @cInclude("drm_fourcc.h");
        @cInclude("gbm.h");
    }
});
