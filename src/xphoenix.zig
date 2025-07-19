pub const Display = @import("backend/display/Display.zig");
pub const DisplayX11 = @import("backend/display/DisplayX11.zig");

pub const Graphics = @import("backend/graphics/Graphics.zig");
pub const GraphicsEgl = @import("backend/graphics/GraphicsEgl.zig");

pub const AtomManager = @import("manager/AtomManager.zig");
pub const ClientManager = @import("manager/ClientManager.zig");
pub const ResourceIdBaseManager = @import("manager/ResourceIdBaseManager.zig");

pub const Client = @import("net/Client.zig");
pub const message = @import("net/message.zig");
pub const Server = @import("net/Server.zig");

pub const err = @import("protocol/error.zig");
pub const Error = err.Error;
pub const ErrorType = err.ErrorType;
pub const event = @import("protocol/event.zig");
pub const opcode = @import("protocol/opcode.zig");
pub const request = @import("protocol/request.zig");
pub const reply = @import("protocol/reply.zig");
pub const x11 = @import("protocol/x11.zig");
pub const xshmfence = @import("protocol/xshmfence.zig");

pub const ConnectionSetup = @import("protocol/handlers/ConnectionSetup.zig");
pub const RequestContext = @import("protocol/handlers/RequestContext.zig");
pub const core = @import("protocol/handlers/core.zig");

pub const extension = @import("protocol/handlers/extension.zig");
pub const Dri3 = @import("protocol/handlers/extension/Dri3.zig");
pub const Present = @import("protocol/handlers/extension/Present.zig");
pub const Randr = @import("protocol/handlers/extension/Randr.zig");
pub const Render = @import("protocol/handlers/extension/Render.zig");
pub const Xfixes = @import("protocol/handlers/extension/Xfixes.zig");

pub const Visual = @import("resource/Visual.zig");
pub const Colormap = @import("resource/Colormap.zig");
pub const Cursor = @import("resource/Cursor.zig");
pub const Drawable = @import("resource/Drawable.zig");
pub const Pixmap = @import("resource/Pixmap.zig");
pub const Window = @import("resource/Window.zig");
pub const Fence = @import("resource/Fence.zig");
pub const EventContext = @import("resource/EventContext.zig");
pub const resource = @import("resource/resource.zig");
pub const Resource = resource.Resource;
pub const ResourceHashMap = resource.ResourceHashMap;

pub const Geometry = @import("misc/Geometry.zig");

pub const c = @import("c.zig");
