const std = @import("std");
const root = @import("root");
const arch = root.arch;
const pcpu = arch.pcpu;
const cbip = root.core.cbip;
const vfs = root.core.vfs;
const log = std.log.scoped(.syscall);

pub export fn testSyscall(arg1: u64, arg2: u64, arg3: u64, arg4: u64, arg5: u64, arg6: u64) callconv(.{ .x86_64_sysv = .{} }) u64 {
    log.debug("testSyscall: args={x}, {x}, {x}, {x}, {x}, {x}", .{ arg1, arg2, arg3, arg4, arg5, arg6 });
    return 0;
}

pub export fn open(path_ptr: u64, path_len: u64, _: u64, _: u64, _: u64, _: u64) callconv(.{ .x86_64_sysv = .{} }) u64 {
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
    
    for (task.vnodes, 0..) |vn, i| {
        if (vn == null) {
            task.vnodes[i] = &vnode.cbip_vnode;
            log.debug("open: assigned fd {} to '{s}'", .{ i, path });
            return i;
        }
    }

    log.err("open: task vnode table full", .{});
    return 0xFFFFFFFFFFFFFFFF;
}

pub export fn get_interface_info(fd: u64, id: u64, info_ptr: u64, _: u64, _: u64, _: u64) callconv(.{ .x86_64_sysv = .{} }) u64 {
    log.debug("get_interface_info: fd={}, id=0x{x}", .{ fd, id });

    const task = pcpu.context().scheduler.currentTask() orelse return 0xFFFFFFFFFFFFFFFF;
    if (fd >= task.vnodes.len) {
        log.warn("get_interface_info: fd {} out of bounds", .{fd});
        return 0xFFFFFFFFFFFFFFFF;
    }

    const vnode = task.vnodes[fd] orelse {
        log.warn("get_interface_info: fd {} is null", .{fd});
        return 0xFFFFFFFFFFFFFFFF;
    };
    
    const bi = vnode.getInterface(id) orelse {
        log.warn("get_interface_info: interface 0x{x} not found on fd {}", .{ id, fd });
        return 0xFFFFFFFFFFFFFFFF;
    };
    
    const info = @as(*cbip.InterfaceInfo, @ptrFromInt(info_ptr));
    info.id = bi.type_id;
    info.vtable_len = bi.vtable.len;
    
    log.debug("get_interface_info: success, vtable_len={}", .{bi.vtable.len});
    return 0;
}

pub export fn call_interface(fd: u64, id: u64, func_idx: u64, arg1: u64, arg2: u64, arg3: u64) callconv(.{ .x86_64_sysv = .{} }) u64 {
    log.debug("call_interface: fd={}, id=0x{x}, idx={}", .{ fd, id, func_idx });

    const task = pcpu.context().scheduler.currentTask() orelse return 0xFFFFFFFFFFFFFFFF;
    if (fd >= task.vnodes.len) return 0xFFFFFFFFFFFFFFFF;
    const vnode = task.vnodes[fd] orelse {
        log.warn("call_interface: fd {} is null", .{fd});
        return 0xFFFFFFFFFFFFFFFF;
    };
    
    const bi = vnode.getInterface(id) orelse {
        log.warn("call_interface: interface 0x{x} not found", .{id});
        return 0xFFFFFFFFFFFFFFFF;
    };

    if (func_idx >= bi.vtable.len) {
        log.err("call_interface: func_idx {} out of range (max {})", .{ func_idx, bi.vtable.len });
        return 0xFFFFFFFFFFFFFFFF;
    }
    
    const func = bi.vtable[func_idx];
    log.debug("call_interface: invoking func at {p} with args({x}, {x}, {x})", .{ func, arg1, arg2, arg3 });

    const f = @as(*const fn (*anyopaque, u64, u64, u64) callconv(.c) u64, @ptrCast(func));
    const result = f(vnode, arg1, arg2, arg3);
    
    log.debug("call_interface: returned {x}", .{result});
    return result;
}
