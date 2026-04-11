const std = @import("std");
const root = @import("root");
const log = std.log.scoped(.cbip);

pub const Inode = struct {
    ref_count: usize = 1,
    
    get_interface: *const fn (self: *Inode, id: u64) InterfaceResult,
    
    deinit_fn: *const fn (self: *Inode) void,

    pub fn ref(self: *Inode) void {
        _ = @atomicRmw(usize, &self.ref_count, .Add, 1, .seq_cst);
    }

    pub fn unref(self: *Inode) void {
        if (@atomicRmw(usize, &self.ref_count, .Sub, 1, .seq_cst) == 1) {
            self.deinit_fn(self);
        }
    }
};

pub const InterfaceID = u64;

/// The Universal Function Signature for all interface calls (Kernel View).
pub const GenericFn = *const fn (
    vnode: *anyopaque,
    arg1: u64,
    arg2: u64,
    arg3: u64,
) callconv(.c) u64;

/// A Vtable is simply a slice of generic function pointers.
pub const Vtable = []const GenericFn;

/// The Result of an interface lookup.
pub const InterfaceResult = struct {
    vtable: ?Vtable,
    context: ?*Inode,
    status: u64 = 0,
};

pub const InterfaceType = struct {
    name: []const u8,
    id: InterfaceID,
    canonical: []const u8,
};

var global_registry: [256]InterfaceType = undefined;
var global_registry_count: usize = 0;

/// Announce an interface type to the global registry.
pub fn announce(name: []const u8, id: InterfaceID, canonical: []const u8) !void {
    for (global_registry[0..global_registry_count]) |entry| {
        if (entry.id == id) {
            if (!std.mem.eql(u8, entry.canonical, canonical)) {
                log.err("Interface ID collision for {s} and {s} with ID 0x{x}", .{ entry.name, name, id });
                return error.IDCollision;
            }
            return;
        }
    }

    if (global_registry_count >= global_registry.len) return error.RegistryFull;

    global_registry[global_registry_count] = .{
        .name = name,
        .id = id,
        .canonical = canonical,
    };
    global_registry_count += 1;
    log.info("Announced interface: {s} (ID: 0x{x})", .{ name, id });
}

pub fn getInterfaceByID(id: InterfaceID) ?InterfaceType {
    for (global_registry[0..global_registry_count]) |entry| {
        if (entry.id == id) return entry;
    }
    return null;
}

// ============================================================================
// COMPTIME GENERATION & TYPE ERASURE
// ============================================================================

/// Generates a unique InterfaceID at comptime based on the canonical type string.
pub fn generateID(comptime T: type) InterfaceID {
    return std.hash.Fnv1a_64.hash(getCanonicalString(T));
}

pub fn getCanonicalString(comptime T: type) []const u8 {
    return comptime blk: {
        @setEvalBranchQuota(10000);
        const info = @typeInfo(T);
        if (info != .@"struct") @compileError("Interface must be a struct of function pointers");

        const base_name = if (@hasDecl(T, "NAME")) T.NAME else @typeName(T);
        var res: []const u8 = base_name ++ "{";

        for (info.@"struct".fields, 0..) |field, i| {
            validateSubset(field.name, field.type);
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

// ============================================================================
// THE FLATTENER & WRAPPER GENERATOR
// ============================================================================

/// Validates that a user's strongly typed function fits into the 4-register limit.
fn validateSubset(comptime name: []const u8, comptime FieldType: type) void {
    const ptr_info = @typeInfo(FieldType);
    if (ptr_info != .pointer) @compileError("Field '" ++ name ++ "' must be a function pointer");

    const fn_info = @typeInfo(ptr_info.pointer.child);
    if (fn_info != .@"fn") @compileError("Field '" ++ name ++ "' must be a function pointer");

    const params = fn_info.@"fn".params;
    if (params.len > 4) {
        @compileError("Function '" ++ name ++ "' has too many arguments (max 4 allowed including ctx)");
    }
}

/// Helper to cast raw u64 registers back to the user's strong argument types.
inline fn castArg(comptime TargetType: type, val: u64) TargetType {
    const info = @typeInfo(TargetType);
    return switch (info) {
        .pointer => @ptrFromInt(@as(usize, @intCast(val))),
        .int => @as(TargetType, @intCast(val)), // Truncates if smaller than 64 bits
        .bool => val != 0,
        .@"enum" => @enumFromInt(val),
        else => @compileError("Unsupported argument type in interface wrapper"),
    };
}

/// Helper to cast the user's strong return type into the raw u64 kernel return.
inline fn castRet(val: anytype) u64 {
    const T = @TypeOf(val);
    if (T == void) return 0;

    const info = @typeInfo(T);
    return switch (info) {
        .pointer => @as(u64, @intCast(@intFromPtr(val))),
        .@"int" => @as(u64, @intCast(val)),
        .@"bool" => if (val) 1 else 0,
        .@"enum" => @as(u64, @intCast(@intFromEnum(val))),
        .@"error_union" => {
            if (val) |v| return castRet(v) else |err| return @intFromError(err);
        },
        else => @compileError("Unsupported return type in interface wrapper"),
    };
}

/// Takes a strongly typed interface struct instance and flattens it into an
/// array of C-callconv GenericFn pointers ready for the kernel dispatcher.
pub fn flatten(comptime impl: anytype) [std.meta.fields(@TypeOf(impl)).len]GenericFn {
    const Interface = @TypeOf(impl);
    const fields = std.meta.fields(Interface);
    var vtable: [fields.len]GenericFn = undefined;

    inline for (fields, 0..) |field, i| {
        const original_fn = @field(impl, field.name);
        const FnType = @typeInfo(field.type).pointer.child; // Get underlying fn signature

        vtable[i] = struct {
            // The generated wrapper that matches the Kernel GenericFn signature
            fn wrapper(ctx: ?*anyopaque, a1: u64, a2: u64, a3: u64) callconv(.c) u64 {
                const params = @typeInfo(FnType).@"fn".params;

                // Construct the exact arguments the user's function expects
                const res = switch (params.len) {
                    0 => original_fn(),
                    1 => original_fn(@ptrCast(@alignCast(ctx))),
                    2 => original_fn(@ptrCast(@alignCast(ctx)), castArg(params[1].type.?, a1)),
                    3 => original_fn(@ptrCast(@alignCast(ctx)), castArg(params[1].type.?, a1), castArg(params[2].type.?, a2)),
                    4 => original_fn(@ptrCast(@alignCast(ctx)), castArg(params[1].type.?, a1), castArg(params[2].type.?, a2), castArg(params[3].type.?, a3)),
                    else => unreachable, // Blocked at comptime by validateSubset
                };

                return castRet(res);
            }
        }.wrapper;
    }

    return vtable;
}
