// Clients can create resources with ids from 0 to 0x001fffff (resource_id_mask).
// To differentiate between each clients resources (with the same ids) each client has a different resource id base,
// that is each bit after 0x001fffff (0xFFE00000). That means that right now a maximum of 0xFFE (4094) clients can connect to
// to the server at once.

const std = @import("std");

const Self = @This();

pub const resource_id_mask: u32 = 0x001fffff;
const resource_id_base_size: u32 = 0xFFF; // Dont change this
const base_bit_shift = @popCount(0xFFFFFFFF - resource_id_base_size) + 1;

free_resource_id_bases: std.StaticBitSet(resource_id_base_size) = .initEmpty(),
resource_id_base_counter: u32 = 1,

pub fn get_next_free(self: *Self) ?u32 {
    if (self.resource_id_base_counter < resource_id_base_size) {
        const index = self.resource_id_base_counter;
        self.resource_id_base_counter += 1;
        return index << base_bit_shift;
    }

    if (self.free_resource_id_bases.toggleFirstSet()) |index| {
        // TODO: Optimize this. Use a counter for when bits are set/unset instead
        if (self.free_resource_id_bases.count() == 0)
            self.resource_id_base_counter = 1;
        return @as(u32, @intCast(index)) << base_bit_shift;
    }

    return null;
}

pub fn free(self: *Self, resource_id_base: u32) void {
    std.debug.assert(resource_id_base > resource_id_mask);
    const index = resource_id_base >> base_bit_shift;
    self.free_resource_id_bases.set(index);
}
