#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#define GL_GLEXT_PROTOTYPES
#include <GL/gl.h>
#include <GL/glext.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>

#include <xkbcommon/xkbcommon.h>

#include <xcb/xcb.h>
#include <xcb/xkb.h>

#ifdef PHX_BACKEND_WAYLAND
#include <wayland-client.h>
#endif

#ifdef PHX_BACKEND_DRM
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_mode.h>
#include <drm_fourcc.h>
#include <gbm.h>
#endif

#include <sys/shm.h>
#include <sys/socket.h>
