# Xphoenix
Xphoenix is a new X server, written from scratch in Zig (not a fork of Xorg server). This X server is designed to be a modern alternative to the Xorg server.

## Current state
Xphoenix is not ready to be used yet. At the moment it can render simple applications that do EGL graphics (fully hardware accelerated) nested in an existing X server.
Running Xphoenix nested will be the only supported mode until Xphoenix has progressed more and can run real-world applications.

## Goals
### Simplicity
Be a simpler X server than the Xorg server by only supporting a subset of the X11 protocol, the features that are needed by relatively modern applications (applications written in the last ~20 years).\
Only relatively modern hardware (made in the last ~15 years) which support linux drm and mesa gbm will be supported, and no server driver interface like the Xorg server. Just like how Wayland compositors work.

### Security
Be safer than the Xorg server by parsing protocol messages automatically. As it's written in Zig, which automatically catches illegal behaviors (such as index out of array bounds).

Applications will be isolated and can only interact with other applications either through a GUI prompt asking for permission,
such as with screen recorders, where it will only be allowed to record the window specified
or by explicitly giving the application permission before launched (such as a window manager or external compositor).\
There will be an option to disable this to make the X server behave like the Xorg server. This will not break existing clients as clients wont receive errors when they try to access more than they need.

### Improvements for modern technology
Support modern hardware better than the Xorg server, such as proper support for multiple monitors (different refresh rates, VRR - not a single framebuffer for the whole collection of displays) and technology like HDR.

### Improved graphics handling
No tearing by default and a built-in compositor. The compositor will get disabled if the user runs an external compositor (client application), such as picom
or if the client runs a fullscreen application and disabled vsync in the application. The goal is to also have lower vsync/compositor latency than the Xorg server.

### New standards
New standards will be developed and documented, such as per-monitor DPI as randr properties.
Applications can use this property to scale their content to the specified DPI for the monitor they are on.

### Extending the X11 protocol
If there is a need for new features (such as HDR) then the X11 protocol will be extended.

### Wayland compatibility
Some applications might only run on Wayland in the future. Such applications should be supported by either Xphoenix support Wayland natively or by running
an external application that works as a proxy between Wayland and X11 (such as 12to11).

### Nested display server
Being able to run Xphoenix nested under X11 or Wayland with hardware acceleration.
This is not only useful for debugging Xphoenix but also for developers who want to test their window manager or compositor without restarting the display server they are running.\
Being able to run Xphoenix under Wayland as an alternative Xwayland server would be a good option.

## Non-goals
### Replacing the Xorg server
The Xorg server will always support more features of the X11 protocol and wider range of hardware (especially older ones).

### Multiple _screens_
Multiple displays (monitors) are going to be supported but not X11 screens.

### Endian-swapped client/server
This can be reconsidered if there is a reason.

### Indirect (remote) GLX.
This is very complex as there are a lot of functions that would need to be implemented. These days remote streaming options are more efficient. Alternatively a proxy for glx could be implemented that does remote rendering.

## Differences between the X11 protocol and Xphoenix
* Several parts of the X11 protocol (core) are mandatory to be implemented by an X server, such as font related operations. However these are not going to be implemented in Xphoenix.
* Strings are in ISO Latin-1 encoding in the X11 protocol unless specified otherwise, however in Xphoenix all strings
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
Run `zig build`, which builds Xphoenix in debug mode. The compiled binary will be available at `./zig-out/bin/xphoenix`. You can alternatively build and run with one command: `zig build run`.

## Dependencies
* [Zig 0.14.1](https://ziglang.org/download/)
* x11 (`xcb`) - for nested mode under X11, when building Xphoenix with `-Dbackends=x11`
* wayland (`wayland-client`, `wayland-egl`) - for nested mode under Wayland, when building Xphoenix with `-Dbackends=wayland` (not currently supported)
* drm (`libdrm`, `gbm`) - for running Xphoenix as a standalone X11 server, when building Xphoenix with `-Dbackends=drm` (not currently supported)
* OpenGL (`libglvnd` which provides both `gl` and `egl`)
