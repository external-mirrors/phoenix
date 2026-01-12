const std = @import("std");
const phx = @import("../phoenix.zig");
const x11 = phx.x11;

const Self = @This();

id: phx.Randr.CrtcId,
x: i32,
y: i32,
width_mm: u32,
height_mm: u32,
status: Status,
rotation: Rotation,
reflection: Reflection,
active_mode_index: usize,
preferred_mode_index: usize,
name: []u8,
modes: []Mode,

pending_filter: phx.Randr.Filter = .bilinear,
pending_transform: phx.Randr.Transform = .{
    // zig fmt: off
    .p11 = phx.fixed.from_comp_float(1.0), .p12 = phx.fixed.from_comp_float(0.0), .p13 = phx.fixed.from_comp_float(0.0),
    .p21 = phx.fixed.from_comp_float(0.0), .p22 = phx.fixed.from_comp_float(1.0), .p23 = phx.fixed.from_comp_float(0.0),
    .p31 = phx.fixed.from_comp_float(0.0), .p32 = phx.fixed.from_comp_float(0.0), .p33 = phx.fixed.from_comp_float(1.0),
    // zig fmt: on
},
pending_filter_params: std.ArrayListUnmanaged(phx.Render.Fixed) = .empty,

current_filter: phx.Randr.Filter = .bilinear,
current_transform: phx.Randr.Transform = .{
    // zig fmt: off
    .p11 = phx.fixed.from_comp_float(1.0), .p12 = phx.fixed.from_comp_float(0.0), .p13 = phx.fixed.from_comp_float(0.0),
    .p21 = phx.fixed.from_comp_float(0.0), .p22 = phx.fixed.from_comp_float(1.0), .p23 = phx.fixed.from_comp_float(0.0),
    .p31 = phx.fixed.from_comp_float(0.0), .p32 = phx.fixed.from_comp_float(0.0), .p33 = phx.fixed.from_comp_float(1.0),
    // zig fmt: on
},
current_filter_params: std.ArrayListUnmanaged(phx.Render.Fixed) = .empty,

properties: PropertyHashMap = .empty,

gamma_ramps_red: std.ArrayListUnmanaged(u16) = .empty,
gamma_ramps_green: std.ArrayListUnmanaged(u16) = .empty,
gamma_ramps_blue: std.ArrayListUnmanaged(u16) = .empty,

pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    var property_it = self.properties.valueIterator();
    while (property_it.next()) |property| {
        property.deinit();
    }
    self.properties.deinit(allocator);

    allocator.free(self.name);
    allocator.free(self.modes);
    self.pending_filter_params.deinit(allocator);
    self.current_filter_params.deinit(allocator);
}

pub fn get_active_mode(self: *const Self) *const Mode {
    return &self.modes[self.active_mode_index];
}

pub fn get_preferred_mode(self: *const Self) *const Mode {
    return &self.modes[self.preferred_mode_index];
}

pub fn get_property(self: *Self, atom: phx.Atom) ?*PropertyValue {
    return self.properties.getPtr(atom.id);
}

pub fn get_property_single_value(self: *Self, comptime DataType: type, atom: phx.Atom) ?DataType {
    if (self.properties.getPtr(atom.id)) |property_value| {
        const union_field_type = comptime property_element_type_to_union_field(DataType);
        if (std.meta.activeTag(property_value.item) == union_field_type and property_value.item.card8_list.items.len > 0) {
            return property_value.item.card8_list.items[0];
        } else {
            return null;
        }
    } else {
        return null;
    }
}

fn property_element_type_to_union_field(comptime DataType: type) PropertyValueDataType {
    return switch (DataType) {
        u8 => .card8_list,
        u16 => .card16_list,
        u32 => .card32_list,
        else => @compileError("Expected DataType to be u8, u16 or u32, was: " ++ @typeName(DataType)),
    };
}

// TODO: Add a max size for properties
pub fn replace_property(
    self: *Self,
    comptime DataType: type,
    property_name: phx.Atom,
    property_type: phx.Atom,
    value: []const DataType,
    ignore_immutable: bool,
) !void {
    if (!ignore_immutable and is_property_immutable(property_name.id))
        return error.AttemptToMutateImmutableProperty;

    var array_list = try std.ArrayList(DataType).initCapacity(self.allocator, value.len);
    errdefer array_list.deinit();
    array_list.appendSliceAssumeCapacity(value);

    var result = try self.properties.getOrPut(self.allocator, property_name.id);
    if (result.found_existing)
        result.value_ptr.deinit();

    const union_field_type = comptime property_element_type_to_union_field(DataType);
    result.value_ptr.* = .{
        .type = property_type.id,
        .item = @unionInit(PropertyValueData, @tagName(union_field_type), array_list),
    };
}

// TODO: Add a max size for properties
fn property_add(
    self: *Self,
    comptime DataType: type,
    property_name: phx.Atom,
    property_type: phx.Atom,
    value: []const DataType,
    operation: enum { prepend, append },
    ignore_immutable: bool,
) !void {
    if (!ignore_immutable and is_property_immutable(property_name.id))
        return error.AttemptToMutateImmutableProperty;

    const union_field_name = comptime property_element_type_to_union_field(DataType);
    if (self.properties.getPtr(property_name.id)) |property| {
        if (property.type != property_type.id)
            return error.PropertyTypeMismatch;

        return switch (operation) {
            .prepend => @field(property.item, union_field_name).insertSlice(0, value),
            .append => @field(property.item, union_field_name).appendSlice(value),
        };
    } else {
        var array_list = try std.ArrayList(DataType).initCapacity(self.allocator, value.len);
        errdefer array_list.deinit();
        array_list.appendSliceAssumeCapacity(value);

        const property = PropertyValue{
            .type = property_type.id,
            .item = @unionInit(PropertyValueData, union_field_name, array_list),
        };
        return self.properties.put(self.allocator, property_name.id, property);
    }
}

pub fn prepend_property(
    self: *Self,
    comptime DataType: type,
    property_name: phx.Atom,
    property_type: phx.Atom,
    value: []const DataType,
    ignore_immutable: bool,
) !void {
    return self.property_add(DataType, property_name, property_type, value, .prepend, ignore_immutable);
}

pub fn append_property(
    self: *Self,
    comptime DataType: type,
    property_name: phx.Atom,
    property_type: phx.Atom,
    value: []const DataType,
    ignore_immutable: bool,
) !void {
    return self.property_add(DataType, property_name, property_type, value, .append, ignore_immutable);
}

pub fn delete_property(self: *Self, property_name: phx.Atom, ignore_immutable: bool) bool {
    if (!ignore_immutable and is_property_immutable(property_name))
        return error.AttemptToMutateImmutableProperty;

    return self.properties.remove(property_name);
}

pub fn is_property_immutable(property_name: phx.Atom) bool {
    return switch (property_name.id) {
        .EDID => true,
        .CloneList => true,
        .CompatibilityList => true,
        .ConnectorNumber => true,
        .ConnectorType => true,
        .Border => true,
        .BorderDimensions => true,
        .GUID => true,
        .TILE => true,
        .@"non-desktop" => true,
        else => false,
    };
}

pub const Mode = struct {
    id: phx.Randr.ModeId,
    width: u32,
    height: u32,
    dot_clock: u32,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    interlace: bool,
};

pub const Status = enum {
    connected,
    disconnected,
};

pub const Rotation = enum {
    rotation_0,
    rotation_90,
    rotation_180,
    rotation_270,
};

pub const Reflection = packed struct {
    horizontal: bool,
    vertical: bool,
};

pub const PropertyValueDataType = enum {
    card8_list,
    card16_list,
    card32_list,
};

pub const PropertyValueData = union(PropertyValueDataType) {
    card8_list: std.ArrayList(x11.Card8),
    card16_list: std.ArrayList(x11.Card16),
    card32_list: std.ArrayList(x11.Card32),
};

pub const PropertyValue = struct {
    type: x11.AtomId,
    item: PropertyValueData,
    valid_values: std.ArrayList(i32),
    range: bool,
    pending: bool,

    pub fn deinit(self: *PropertyValue) void {
        switch (self.item) {
            inline else => |*item| item.deinit(),
        }
    }

    pub fn get_size_in_bytes(self: *const PropertyValue) usize {
        return switch (self.item) {
            inline else => |*item| item.items.len * self.get_data_type_size(),
        };
    }

    pub fn get_data_type_size(self: *const PropertyValue) usize {
        return switch (self.item) {
            .card8_list => 1,
            .card16_list => 2,
            .card32_list => 4,
        };
    }
};

pub const PropertyHashMap = std.HashMapUnmanaged(x11.AtomId, PropertyValue, struct {
    pub fn hash(_: @This(), key: x11.AtomId) u64 {
        return @intFromEnum(key);
    }

    pub fn eql(_: @This(), a: x11.AtomId, b: x11.AtomId) bool {
        return a == b;
    }
}, std.hash_map.default_max_load_percentage);
