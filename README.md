# Phoenix
Phoenix is a new X server, written from scratch in Zig (not a fork of Xorg server). This X server is designed to be a modern alternative to the Xorg server.

## Current state
Phoenix is not ready to be used yet. At the moment it can render simple applications that do GLX, EGL or Vulkan graphics (fully hardware accelerated) nested in an existing X server.
Running Phoenix nested will be the only supported mode until Phoenix has progressed more and can run real-world applications.

## Goals
### Simplicity
Be a simpler X server than the Xorg server by only supporting a subset of the X11 protocol, the features that are needed by relatively modern applications (applications written/updated in the last ~20 years).\
This includes _all_ software that _you_ use, even old gtk2 applications.\
Only relatively modern hardware (made/updated in the last ~15-20 years) which support linux drm and mesa gbm will be supported, and no server driver interface like the Xorg server. Just like how Wayland compositors work.

### Security
Be safer than the Xorg server by parsing protocol messages automatically. As it's written in Zig, it also automatically catches illegal behaviors (such as index out of array bounds) when building with the `ReleaseSafe` option.

Applications will be isolated from each other by default and can only interact with other applications either through a GUI prompt asking for permission,\
such as with screen recorders, where it will only be allowed to record the window specified
or by explicitly giving the application permission before launched (such as a window manager or external compositor).\
This will not break existing clients as clients wont receive errors when they try to access more than they need, they will instead receive dummy data.\
Applications that rely on global hotkeys should work, as long as a modifier key is pressed (keys such as ctrl, shift, alt and super).\
If an application needs global hotkeys without pressing a modifier key then it needs to be given permissions to do so (perhaps by adding a command to run a program with more X11 permissions).\
There will be an option to disable this to make the X server behave like the Xorg server.

### Improvements for modern technology
Support modern hardware better than the Xorg server, such as proper support for multiple monitors (different refresh rates, VRR - not a single framebuffer for the whole collection of displays) and technology like HDR.

### Improved graphics handling
No tearing by default and a built-in compositor. The compositor will get disabled if the user runs an external compositor (client application), such as picom or if the client runs a fullscreen application.\
The goal is to also have lower vsync/compositor latency than the Xorg server.

### New standards
New standards will be developed and documented, such as per-monitor DPI as randr properties.
Applications can use this property to scale their content to the specified DPI for the monitor they are on.

### Extending the X11 protocol
If there is a need for new features (such as HDR) then the X11 protocol will be extended.

### Wayland compatibility
Some applications might only run on Wayland in the future. Such applications should be supported by either Phoenix supporting Wayland natively or by running
an external application that works as a bridge between Wayland and X11 (such as 12to11).

### Nested display server
Being able to run Phoenix nested under X11 or Wayland with hardware acceleration.
This is not only useful for debugging Phoenix but also for developers who want to test their window manager or compositor without restarting the display server they are running.\
Being able to run Phoenix under Wayland as an alternative Xwayland server would be a good option.

## Non-goals
### Replacing the Xorg server
The Xorg server will always support more features of the X11 protocol and wider range of hardware (especially older ones).

### Multiple _screens_
Multiple displays (monitors) are going to be supported but not X11 screens.

### Exclusive access
GrabServer has no effect in Phoenix.

### Endian-swapped client/server
This can be reconsidered if there is a reason.

### Indirect (remote) GLX.
This is very complex as there are a lot of functions that would need to be implemented. These days remote streaming options are more efficient. Alternatively a proxy for glx could be implemented that does remote rendering.

## Differences between the X11 protocol and Phoenix
### Core protocol
Several parts of the X11 protocol (core) are mandatory to be implemented by an X server, such as many font related operations.\
However these are not going to be implemented in Phoenix, except for the simple ones that applications actually use (such as font operations used for cursors).\
This will not affect applications that users actually use, even if they use old gtk2 applications.

### Strings
Strings are in ISO Latin-1 encoding in the X11 protocol unless specified otherwise, however in Phoenix all strings are UTF-8 unless the protocol states that it's not an ISO Latin-1 string.

## Installing
Run:
```sh
zig build -Doptimize=ReleaseSafe
sudo zig build install -p /usr/local -Doptimize=ReleaseSafe
```

## Uninstalling
Zig does currently not support the uninstall command so you have to remove files manually:
```sh
sudo rm /usr/local/bin/phoenix
```

## Building (for development)
Run `zig build`, which builds Phoenix in debug mode. The compiled binary will be available at `./zig-out/bin/phoenix`. You can alternatively build and run with one command: `zig build run`.

### Generate x11 protocol documentation
Run `zig build -Dgenerate-docs=true`. This will generate `.txt` files in `./zig-out/protocol/`. This generates x11 protocol documentation in the style of the official protocol documentation. The documentation is automatically generated from the protocol struct code.
Note that the generated documentation feature is a work-in-progress.

## Dependencies
* [Zig 0.14.1](https://ziglang.org/download/)
* x11 (`xcb`) - for nested mode under X11, when building Phoenix with `-Dbackends=x11`
* wayland (`wayland-client`, `wayland-egl`) - for nested mode under Wayland, when building Phoenix with `-Dbackends=wayland` (not currently supported)
* drm (`libdrm`, `gbm`) - for running Phoenix as a standalone X11 server, when building Phoenix with `-Dbackends=drm` (not currently supported)
* OpenGL (`libglvnd` which provides both `gl` and `egl`)

## License
This software is licensed under GPL-3.0-only, see the LICENSE file for more information.

## FAQ
### Isn't it easier to write a Wayland compositor?
Despite popular belief, writing a simple X server that works in practice for a wide range of applications is easier to do than it is to write a Wayland compositor (+ related software).\
Not many people have attempted to write an X server from scratch or have proper understanding of the protocol, but if you do you can see that it's quite simple.

### Doesn't X11 have fundamental issues with tearing/multiple monitors/hdr/security/etc that can't be fixed?
No, most information about how X11 works online is wrong. Some of this misinformation has even been spread by Wayland compositor developers. These issues are related to the X.org server, not the X11 protocol.\
When 10-bit color mode is enabled in the X.org server it can break some applications such as steam which fails to start, but all of these issues can be solved without affecting client applications.