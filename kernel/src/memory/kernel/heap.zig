const std = @import("std");
const log = std.log.scoped(.kheap);
const paging = @import("paging.zig");
const pmm = @import("../pmm.zig");
const vmm = @import("vmm.zig");

const utils = @import("../../utils.zig");
const globals = @import("../../globals.zig");
const VirtualAddress = paging.VirtualAddress;

const cpu = @import("../../cpu.zig");

const Allocator = std.mem.Allocator;

pub fn init() void {
    pmm.init() catch @panic("failed to init pmm");

    paging.init() catch |err| {
        log.err("paging.init error: {}", .{err});
        @panic("failed to init paging {}");
    };

    vmm.init() catch @panic("failed to init vmm");
}

pub fn allocatePages(num_pages: usize) !u64 {
    const alloc_start = try vmm.allocatePageBlock(num_pages);

    for (0..num_pages) |i| {
        const vaddr = alloc_start + i * utils.PAGE_SIZE;
        const phys_page = try pmm.allocatePage();
        try paging.mapPage(
            @bitCast(vaddr),
            phys_page,
            .{ .present = true, .user_supervisor = .supervisor, .read_write = .read_write },
        );

        cpu.invlpg(vaddr);
    }

    return alloc_start;
}

pub fn freePages(start_addr: usize, num_pages: usize) !void {
    for (0..num_pages) |page_index| {
        const page_vaddr = start_addr + page_index * utils.PAGE_SIZE;
        const phys_addr = paging.getPaddr(@bitCast(page_vaddr)) catch unreachable;

        try paging.unmapPage(@bitCast(start_addr + page_index * utils.PAGE_SIZE));
        try pmm.freePage(phys_addr);

        cpu.invlpg(page_vaddr);
    }

    try vmm.freePageBlock(start_addr, num_pages);
}

pub const vtable = Allocator.VTable{
    .alloc = alloc,
    .free = free,
    .resize = resize,
};

pub const page_allocator: Allocator = Allocator{
    .ptr = undefined,
    .vtable = &vtable,
};

fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
    const num_pages = std.math.divCeil(usize, len, utils.PAGE_SIZE) catch unreachable;

    const start_addr = allocatePages(num_pages) catch |err| {
        log.err("failed to allocate pages in kernel: {}", .{err});
        unreachable;
    };

    return @ptrFromInt(start_addr);
}

fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    const start_addr = @intFromPtr(buf.ptr);
    const num_pages = std.math.divCeil(usize, buf.len, utils.PAGE_SIZE) catch unreachable;
    freePages(start_addr, num_pages) catch |err| {
        log.err("failed to free pages becuase of error: {}", .{err});
        @panic("failed to free pages");
    };
}

pub fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
    return false;
}
