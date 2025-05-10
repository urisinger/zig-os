const std = @import("std");
const log = std.log;
const paging = @import("../paging.zig");
const pmm = @import("../pmm.zig");
const vmm = @import("vmm.zig");

const utils = @import("../../utils.zig");
const globals = @import("../../globals.zig");
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


pub fn allocateExecutablePageWithCode(code: []const u8) !u64 {
    const temp_flags = .{ .present = true, .read_write = .read_write, .user_supervisor = .supervisor };

    std.log.info("g", .{});
    const virt = try allocatePagesWithFlags(1, temp_flags);

    const virt_ptr: [*]u8 = @ptrFromInt(virt);
    @memcpy(virt_ptr, code);

    const phys = paging.getPaddr(@bitCast(virt)) catch unreachable;
    try paging.unmapPage(@bitCast(virt));

    const exec_flags = .{ .present = true, .read_write = .read_execute, .user_supervisor = .user };
    try paging.mapPage(@bitCast(virt), phys, exec_flags);

    return virt;
}

pub fn allocatePagesWithFlags(num_pages: usize, flags: paging.MmapFlags ) !u64 {
    std.log.info("h", .{});
    const alloc_start = try vmm.allocatePageBlock(num_pages);

    for (0..num_pages) |i| {
        const phys_page = try pmm.allocatePage();
        try paging.mapPage(
            @bitCast(alloc_start + i * utils.PAGE_SIZE),
            phys_page,
            flags,
        );
    }

    return alloc_start;
}

pub fn freePages(start_addr: usize, num_pages: usize) !void {
    for (0..num_pages) |page_index| {
        const page_vaddr = start_addr + page_index * utils.PAGE_SIZE;
        const phys_addr = paging.getPaddr(@bitCast(page_vaddr)) catch unreachable;

        try paging.unmapPage(@bitCast(start_addr + page_index * utils.PAGE_SIZE));
        try pmm.freePage(phys_addr);
    }

    try vmm.freePageBlock(start_addr, num_pages);
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

    const start_addr = allocatePagesWithFlags(num_pages, .{ .present = true, .read_write = .read_write }) catch |err| {
        log.err("failed to allocate pages in kernel: {}", .{err});
        return null;
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
