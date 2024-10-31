const std = @import("std");
const log = std.log;
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

const utils = @import("../utils.zig");
const globals = @import("../globals.zig");
const VirtualAddress = paging.VirtualAddress;

const Allocator = std.mem.Allocator;

pub fn init() void {
    pmm.init() catch @panic("failed to init pmm");

    paging.init() catch |err| {
        log.err("paging.init error: {}", .{err});
        @panic("failed to init paging {}");
    };

    vmm.init() catch @panic("failed to init vmm");
}

pub const page_allocator: Allocator = Allocator{
    .ptr = undefined,
    .vtable = &Allocator.VTable{
        .alloc = alloc,
        .free = free,
        .resize = resize,
    },
};

fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
    const num_pages = std.math.divCeil(usize, len, utils.PAGE_SIZE) catch unreachable;

    const alloc_start = vmm.allocate_page_block(num_pages) catch |err| {
        log.err("Could not allocate virtual pages: {}", .{err});
        return null;
    };

    for (0..num_pages) |i| {
        const phys_page = pmm.allocate_page() catch |err| {
            log.err("Could not allocate physical page: {}", .{err});
            return null;
        };

        paging.map_page(@bitCast(alloc_start + i * utils.PAGE_SIZE), phys_page, .{ .present = true, .read_write = .read_write }) catch |err| {
            log.err("Could not map virtual page: {}", .{err});
            return null;
        };
    }

    return @ptrFromInt(alloc_start);
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    const start_addr = @intFromPtr(buf.ptr);
    const num_pages = (buf.len + utils.PAGE_SIZE - 1) / utils.PAGE_SIZE;

    for (0..num_pages) |page_index| {
        const page_vaddr = start_addr + page_index * utils.PAGE_SIZE;

        const phys_page = paging.get_paddr(@bitCast(page_vaddr)) catch unreachable;

        pmm.free_page(phys_page) catch unreachable;
    }
}

pub fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
    return false;
}
