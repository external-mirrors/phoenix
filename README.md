# XPhoenix
XPhoenix is a new X server, written from scratch (not a fork of Xorg server) in Zig. This X server is designed to be a modern alternative to the Xorg server.

## Current state
XPhoenix can render simple applications that do EGL graphics (fully hardware accelerated) nested in an existing X server, it's not ready to be used yet.
Running XPhoenix nested will be the only supported mode until XPhoenix has progressed more and can run real-world applications.

## Goals
* Be a simpler X server than the Xorg server by only supporting a subset of the X11 protocol,
the features that are needed by relatively modern applications (applications written in the last ~20 years)
and only support relatively modern hardware by only support linux drm and mesa gbm (like Wayland compositors do)
and no server driver interface like the Xorg server.
* Safer than the Xorg server by parsing protocol messages automatically.
As it's written in Zig, it also automatically catches illegal behaviors (such as index out of array bounds).
* Support modern technology better than the Xorg server.
Proper support for multiple monitors (different refresh rates, VRR - not a single framebuffer for the whole collection of displays) and technology like HDR.
* No tearing by default and a built-in compositor. The compositor will get disabled if the user runs a client compositor (such as picom).
* Less vsync/compositor latency than the Xorg server.
* Provide new standards, such as per-monitor DPI as randr properties.
Applications can use this property to scale their content to the specified DPI for the monitor they are on.
* Support wayland applications, either directly or indirectly (internally or externally).
* Support (hardware accelerated) nested X server or to be used as an XWayland server.

## Non-goals
* Replacing the Xorg server. The Xorg server will always support more features of the X11 protocol and wider range of hardware (especially older ones).
* Multiple _screens_. Multiple displays (monitors) are going to be supported but not X11 screens.
* Endian-swapped client/server. This can be considered if there is a reason.
* Indirect (remote) GLX.

## Differences between X11 protocol and XPhoenix implementation
* Strings are in ISO Latin-1 encoding in the X11 protocol unless specified otherwise, however in XPhoenix all strings
are UTF-8 unless the protocol states that it's not an ISO Latin-1 string.

## Installing
Run:
```sh
zig build -Doptimize=ReleaseSafe
sudo zig build install -p /usr/local -Doptimize=ReleaseSafe
```

## Uninstalling
Zig does currently not support the uninstall command so you have to remove files manually:
```sh
sudo rm /usr/local/bin/xphoenix
```

## Building (for development)
Run `zig build`, which builds XPhoenix in debug mode. The compiled binary will be available at `./zig-out/bin/xphoenix`. You can alternatively build and run with one command: `zig build run`.

## Dependencies
* [Zig 0.14.1](https://ziglang.org/download/)
* x11 (`xcb`) - for nested mode under X11, when building XPhoenix with `-Dbackends=x11`
* wayland (`wayland-client`, `wayland-egl`) - for nested mode under Wayland, when building XPhoenix with `-Dbackends=wayland` (not currently supported)
* drm (`libdrm`, `gbm`) - for running XPhoenix as a standalone X11 server, when building XPhoenix with `-Dbackends=drm` (not currently supported)
* OpenGL (`libglvnd` which provides both `gl` and `egl`)
