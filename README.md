# Phoenix
Phoenix is a new X server, written from scratch in Zig (not a fork of Xorg server). This X server is designed to be a modern alternative to the Xorg server.

## Current state
Phoenix is not ready to be used yet. At the moment it can render simple applications that do GLX, EGL or Vulkan graphics (fully hardware accelerated) nested in an existing X server.
Running Phoenix nested will be the only supported mode until Phoenix has progressed more and can run real-world applications.

## Goals
### Simplicity
Be a simpler X server than the Xorg server by only supporting a subset of the X11 protocol, the features that are needed by relatively modern applications (applications written/updated in the last ~20 years).\
This includes _all_ software that _you_ use, even old gtk2 applications.\
Only relatively modern hardware (made/updated in the last ~15-20 years) with drivers that implement the Linux DRM and Mesa GBM APIs will be supported. There won't be a server driver interface like in the Xorg server.\
This is similar to how Wayland compositors display graphics.

I may be open to accepting pull requests that add support for older devices that don't support the Linux DRM API later on in the project if users absolutely need it (by adding it as a backend implementation in `src/backend/display`).

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

### Legacy visuals
Only `TrueColor` visual will be supported, no monochrome monitors. It will be possible to render to arbitrary outputs,
but the middle layer would have to convert the image from `TrueColor` to the output format.

### Multiple _screens_
Multiple displays (monitors) are going to be supported but not X11 screens.

### Exclusive access
GrabServer has no effect in Phoenix.

### Endian-swapped client/server
This can be reconsidered if there is a reason.

### Indirect (remote) GLX
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
* libxkbcommon
* x11 (`xcb`) - for nested mode under X11, when building Phoenix with `-Dbackends=x11`
* wayland (`wayland-client`, `wayland-egl`) - for nested mode under Wayland, when building Phoenix with `-Dbackends=wayland` (not currently supported)
* drm (`libdrm`, `gbm`) - for running Phoenix as a standalone X11 server, when building Phoenix with `-Dbackends=drm` (not currently supported)
* OpenGL (`libglvnd` which provides both `gl` and `egl`)

## License
This software is licensed under GPL-3.0-only, see the LICENSE file for more information.

## FAQ
### Isn't it easier to write a Wayland compositor?
Despite popular belief, writing a simple X server that works in practice for a wide range of applications is easier to do than it is to write a Wayland compositor (+ related software).\
Not many people have attempted to write an X server from scratch or have a proper understanding of the protocol, but if you do you can see that it's quite simple.

### Why write a new X11 server instead of a Wayland compositor?
To keep it short: my applications can't ever work properly on Wayland, mainly [GPU Screen Recorder UI](https://git.dec05eba.com/gpu-screen-recorder-ui/about/). Many features of [GPU Screen Recorder UI](https://git.dec05eba.com/gpu-screen-recorder-ui/about/) don't work properly on Wayland.\
A large number of non-standard graphical applications can simply never work properly on Wayland.\
If it were to use the Wayland protocol only then it wouldn't work at all (and can't ever work). It has to rely on Xwayland and even in that case it faces many issues and has to rely on undefined behaviors in each Wayland compositor, which may or may not work.\
Some things are implemented by bypassing the Wayland compositor and interfacing the Linux kernel directly with root access instead, which comes with a lot of issues.\
One of these things where it needs to bypass the Wayland compositor and can't use Xwayland either is global shortcuts. Despite there being a XDG desktop portal protocol for global shortcuts it's mostly useless. It only works (somewhat) on KDE Plasma.\
The protocol for global shortcuts is vague and it's implemented differently in incompatible ways in every Wayland compositor, and in Hyprland for example it's implemented in way where it's not usable for graphical applications. It's also not implemented at all for a large number of Wayland compositors.\
Read more about it this old post of mine: [https://dec05eba.com/2024/03/29/wayland-global-hotkeys-shortcut-is-mostly-useless/](https://dec05eba.com/2024/03/29/wayland-global-hotkeys-shortcut-is-mostly-useless/). This is one of the main reasons why you don't see applications supporting global shortcuts on Wayland.\
Global shortcuts is a mandatory feature of [GPU Screen Recorder UI](https://git.dec05eba.com/gpu-screen-recorder-ui/about/), it can't function without it.\
My own application [GPU Screen Recorder GTK](https://git.dec05eba.com/gpu-screen-recorder-gtk/about/) is one of the first (if not the first) real application to support the global shortcuts protocol.\
This is not an issue in X11 as the X11 doesn't have a protocol for "global shortcuts", it instead allows application to freely listen to keyboard inputs and implement it however they want (note that this can be done while preventing keyloggers).\
X11 works in this case because it's simpler (which is a caused by a difference in philosophy, as explained below). Global shortcuts on Wayland is complex enough that it ended up crashing both Hyprland and Gnome desktop portals when using it.\
I ended up creating a [pull request](https://github.com/hyprwm/xdg-desktop-portal-hyprland/pull/241) to fix that crash in the Hyprland desktop portal.\
This is just one issue with Wayland that GPU Screen Recorder UI has. There are many more, which are fundamental issues that are never fixable.

Every developer that has tried to write applications that try to do anything unsual has experienced these problems on Wayland.

Even if I were to make my own Wayland compositor and fix these issues it would need to break the philosophy of Wayland (it would basically require it to work like X11) and that compositor would be the only
compositor to ever work with my applications.\
That would tie users to a specific desktop experience as on Wayland the Wayland compositor implementation is tied to the user experience (desktop environment).\
It would be no different than making a new X11 server, except with a new X11 server it works with every window manager/desktop environment and doesn't break existing applications or require them to rewrite anything (for no good reason).\
In general you can't just write software that works with every Wayland compositor, you instead target specific Wayland compositors. A lot of software that claim to be Wayland software
are actually KWin (KDE Plasma), Wlroots (Sway, River, etc) or Mutter (Gnome) specific software.

The main issue with Wayland is not a technical one but in it's philosophy. X11 is "mechanism over policy" while Wayland is "policy over mechanism".\
On X11 you have simple but powerful constructs that can be used for a wide range of things while on Wayland each feature is designed specifically to what
the Wayland compositor developers had in mind (a vendored experience), specifically for their Wayland compositor. No more no less.\
This is also the reason why it takes far longer time for a decision to be made in the Wayland protocol than in the X11 protocol (several years vs 2 months) and the Wayland solution (or desktop portal solution) ends up being less flexible and often times up 1000 times more complex for applications (and the Wayland compositor) to implement.

Almost all of the issues people have had with X11 are not issues in X11 protocol, but the Xorg server. Some others (such as "security") are minor issues that are easily solvable without requiring any changes to the X11 protocol.

There are many more issues with Wayland that are not mentioned here.

### Doesn't X11 have fundamental issues with tearing/multiple monitors/hdr/security/etc that can't be fixed?
No, most information about how X11 works online is wrong. Some of this misinformation has even been spread by Wayland compositor developers. These issues are related to the X.org server, not the X11 protocol.\
When 10-bit color mode is enabled in the Xorg server it can break some applications such as steam which fails to start, but all of these issues can be solved without affecting client applications, even without introducing a new X11 protocol extension.