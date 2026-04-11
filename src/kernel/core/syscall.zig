const std = @import("std");
const root = @import("root");
const arch = root.arch;
const pcpu = arch.pcpu;
const cbip = root.core.cbip;
const vfs = root.core.vfs;
const log = std.log.scoped(.syscall);

pub const syscall_table: [2]?*const fn (u64, u64, u64, u64, u64, u64) callconv(.{ .x86_64_sysv = .{} }) u64 = [2]?*const fn (u64, u64, u64, u64, u64, u64) callconv(.{ .x86_64_sysv = .{} }) u64{
    &open,
    &call_interface,
};

pub export fn open(path_ptr: u64, path_len: u64, interface: u64, _: u64, _: u64, _: u64) callconv(.{ .x86_64_sysv = .{} }) u64 {
    const path = @as([*]const u8, @ptrFromInt(path_ptr))[0..path_len];
    log.debug("open: path='{s}'", .{path});

    const task = pcpu.context().scheduler.currentTask() orelse {
        log.err("open: no current task", .{});
        return 0xFFFFFFFFFFFFFFFF;
    };

    const vnode = vfs.lookup(path) orelse {
        log.warn("open: vfs lookup failed for '{s}'", .{path});
        return 0xFFFFFFFFFFFFFFFF;
    };

    log.debug("hi", .{});
    const res = vnode.requestInterface(interface);
    
    // If the driver doesn't support this interface or is busy
    if (res.status != 0 or res.vtable == null) {
        log.warn("open: vnode '{s}' does not support interface 0x{x}", .{path, interface});
        return 0xFFFFFFFFFFFFFFFF;
    }

    // 3. Find a free slot in the task's handle table (FD table)
    for (&task.fd_table, 0..) |*slot, i| {
        if (slot.* == null) { // Assuming null vtable means empty slot
            slot.* = .{
                .vnode = vnode,
                .vtable = res.vtable.?,   // The driver's function pointers
            };
            
            log.debug("open: assigned fd {} to '{s}' (interface 0x{x})", .{ i, path, interface });
            return i;
        }
    }

    log.err("open: task fd table full", .{});
    return 0xFFFFFFFFFFFFFFFF;
}

pub export fn call_interface(fd: u64, func_idx: u64, arg1: u64, arg2: u64, arg3: u64, arg4: u64) callconv(.{ .x86_64_sysv = .{} }) u64 {
    log.debug("call_interface: fd={}, idx={}", .{ fd, func_idx });

    const task = pcpu.context().scheduler.currentTask() orelse return 0xFFFFFFFFFFFFFFFF;
    if (fd >= task.fd_table.len) return 0xFFFFFFFFFFFFFFFF;
    const vnode = task.fd_table[fd] orelse {
        log.warn("call_interface: fd {} is null", .{fd});
        return 0xFFFFFFFFFFFFFFFF;
    };

    if (func_idx >= vnode.vtable.len) {
        log.err("call_interface: func_idx {} out of range (max {})", .{ func_idx, vnode.vtable.len });
        return 0xFFFFFFFFFFFFFFFF;
    }

    const func = vnode.vtable[func_idx];
    log.debug("call_interface: invoking func at {p} with args({x}, {x}, {x}, {x})", .{ func, arg1, arg2, arg3, arg4 });

    const f = @as(*const fn (*anyopaque, u64, u64, u64) callconv(.c) u64, @ptrCast(func));
    const result = f(@ptrCast(vnode.vnode), arg1, arg2, arg3);

    log.debug("call_interface: returned {x}", .{result});
    return result;
}
