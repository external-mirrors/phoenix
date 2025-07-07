const config = @import("config");

pub usingnamespace @cImport({
    if (config.backends.x11)
        @cInclude("xcb/xcb.h");

    if (config.backends.wayland)
        @cInclude("wayland-client.h");

    if (config.backends.drm) {
        @cInclude("xf86drm.h");
        @cInclude("xf86drmMode.h");
        @cInclude("drm_mode.h");
        @cInclude("drm_fourcc.h");
    }
});
