const xph = @import("../xphoenix.zig");
const x11 = xph.x11;

id: xph.Glx.ContextId,
visual: *const xph.Visual,
is_direct: bool,
// screen
// share_list
client_owner: *xph.Client,
