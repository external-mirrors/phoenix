// Clients can create resources with ids from 0 to 0x001FFFFF (2097151) (resource_id_mask).
// To differentiate between each clients resources (with the same ids) each client has a different resource id base,
// that is each bit after 0x001FFFFF excluding the top 3 bits (0x1FE00000). That means that right now a maximum of 0xFF+1 (256) clients can connect to
// to the server at once.

const std = @import("std");

const Self = @This();

pub const resource_id_mask: u32 = 0x001FFFFF;
pub const resource_id_base_mask: u32 = 0xFFFFFFFF - resource_id_mask;
pub const resource_id_base_size: u32 = 0xFF; // Dont change this
const base_bit_shift: u32 = @popCount(@as(u32, resource_id_mask)) + 1;

free_resource_id_bases: std.StaticBitSet(resource_id_base_size) = .initFull(),

pub fn get_next_free(self: *Self) ?u32 {
    if (self.free_resource_id_bases.toggleFirstSet()) |index| {
        return @as(u32, @intCast(index)) << base_bit_shift;
    }
    return null;
}

pub fn free(self: *Self, resource_id_base: u32) void {
    std.debug.assert(resource_id_base > resource_id_mask);
    const index = resource_id_get_base_index(resource_id_base);
    self.free_resource_id_bases.set(index);
}

pub inline fn resource_id_get_base_index(resource_id: u32) u32 {
    return resource_id >> base_bit_shift;
}
