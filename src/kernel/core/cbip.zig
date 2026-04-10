const std = @import("std");
const root = @import("root");
const log = std.log.scoped(.cbip);

pub const InterfaceID = u64;

/// A single hardware device (Vnode) can export multiple interfaces.
pub const Vnode = struct {
    name: []const u8,
    interfaces: [16]BoundInterface = undefined,
    interface_count: usize = 0,

    pub fn bind(self: *Vnode, type_id: InterfaceID, vtable: []const *const anyopaque) !void {
        // Check if type_id is announced
        var found = false;
        for (global_registry[0..global_registry_count]) |entry| {
            if (entry.id == type_id) {
                found = true;
                break;
            }
        }
        if (!found) return error.TypeNotAnnounced;

        if (self.interface_count >= self.interfaces.len) return error.TooManyInterfaces;
        
        self.interfaces[self.interface_count] = .{
            .type_id = type_id,
            .vtable = vtable,
        };
        self.interface_count += 1;
        log.info("Bound interface 0x{x} to vnode {s}", .{type_id, self.name});
    }

    pub fn getInterface(self: *Vnode, id: InterfaceID) ?BoundInterface {
        for (self.interfaces[0..self.interface_count]) |bi| {
            if (bi.type_id == id) return bi;
        }
        return null;
    }
};

pub const BoundInterface = struct {
    type_id: InterfaceID,
    vtable: []const *const anyopaque,
};

pub const InterfaceType = struct {
    name: []const u8, // Debug only
    id: InterfaceID,
    canonical: []const u8,
};

pub const InterfaceInfo = extern struct {
    id: InterfaceID,
    vtable_len: u64,
};

var global_registry: [256]InterfaceType = undefined;
var global_registry_count: usize = 0;

/// Announce an interface type to the global registry.
/// This is idempotent.
pub fn announce(name: []const u8, id: InterfaceID, canonical: []const u8) !void {
    // Check if it already exists
    for (global_registry[0..global_registry_count]) |entry| {
        if (entry.id == id) {
            if (!std.mem.eql(u8, entry.canonical, canonical)) {
                log.err("Interface ID collision for {s} and {s} with ID 0x{x}", .{entry.name, name, id});
                return error.IDCollision;
            }
            return; // Idempotent
        }
    }
    
    if (global_registry_count >= global_registry.len) return error.RegistryFull;
    
    global_registry[global_registry_count] = .{
        .name = name,
        .id = id,
        .canonical = canonical,
    };
    global_registry_count += 1;
    log.info("Announced interface: {s} (ID: 0x{x})", .{name, id});
}

pub fn getInterfaceByID(id: InterfaceID) ?InterfaceType {
    for (global_registry[0..global_registry_count]) |entry| {
        if (entry.id == id) return entry;
    }
    return null;
}

/// Generates a unique InterfaceID at comptime based on the canonical type string.
pub fn generateID(comptime name: []const u8, comptime T: type) InterfaceID {
    return std.hash.Fnv1a_64.hash(getCanonicalString(name, T));
}

pub fn getCanonicalString(comptime name: []const u8, comptime T: type) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(10000);
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("Must be struct");

        var res: []const u8 = name ++ "{";
        
        for (info.@"struct".fields, 0..) |field, i| {
            const separator = if (i > 0) "," else "";
            res = res ++ separator ++ field.name ++ ":" ++ getTypeName(field.type);
        }
        
        break :blk res ++ "}";
    };
}

fn getTypeName(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .void => "void",
        .bool => "bool",
        .int => |i| (if (i.signedness == .signed) "i" else "u") ++ std.fmt.comptimePrint("{}", .{i.bits}),
        .pointer => |ptr| {
            const prefix = if (ptr.size == .slice) "[]" else "*";
            return prefix ++ getTypeName(ptr.child);
        },
        .optional => |opt| "?" ++ getTypeName(opt.child),
        .@"fn" => |f| {
            var res: []const u8 = "fn(";
            for (f.params, 0..) |param, i| {
                const sep = if (i > 0) "," else "";
                const p_type = if (param.type) |pt| getTypeName(pt) else "anyopaque";
                res = res ++ sep ++ p_type;
            }
            const ret_type = if (f.return_type) |rt| getTypeName(rt) else "void";
            return res ++ ")" ++ ret_type;
        },
        .error_set => "error",
        .@"enum" => "enum",
        .@"union" => "union",
        .@"struct" => "struct",
        .@"opaque" => "opaque",
        else => @typeName(T),
    };
}
