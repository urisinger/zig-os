const std = @import("std");
const log = std.log;

const utils = @import("../utils.zig");
const globals = @import("../globals.zig");

const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const MmapFlags = paging.MmapFlags;

const BitmapAllocator = @import("allocator.zig").BitmapAllocator;
const Error = @import("allocator.zig").Error;

var allocator: ?BitmapAllocator = null;
var heap_start: u64 = 0;

const heap_size = utils.GB(2);

pub fn init() !void {
    heap_start = std.mem.alignForward(u64, @intFromPtr(&globals.kernel_end), utils.PAGE_SIZE);

    const num_pages: usize = std.mem.alignForward(u64, heap_size, utils.PAGE_SIZE) / utils.PAGE_SIZE;
    const bitmap_size = (num_pages + 31) / 32;
    const bitmap_bytes = bitmap_size * 4;
    const bitmap_num_pages = (bitmap_bytes + utils.PAGE_SIZE - 1) / utils.PAGE_SIZE;

    for (0..bitmap_num_pages) |i| {
        const vaddr = i * utils.PAGE_SIZE + heap_start;
        const paddr = pmm.allocate_page();
        paging.map_page(@bitCast(vaddr), paddr, 1, MmapFlags{
            .present = true,
            .read_write = .read_write,
        });
    }

    allocator = BitmapAllocator{ .bitmap_ptr = @alignCast(@ptrCast(@as([*]u8, @ptrFromInt(heap_start)) + globals.hhdm_offset)), .num_pages = num_pages };

    for (0..bitmap_num_pages) |i| {
        allocator.?.unfree_page(i);
    }
}

pub fn allocate_page() !u64 {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    return allocator.?.allocate_page();
}

pub fn free_page(page: u64) !void {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    try allocator.?.free_page(page);
}

pub fn allocate_page_block(num_pages: usize) !u64 {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    return allocator.?.allocate_page_block(num_pages);
}

pub fn free_page_block(page: u64, num_pages: usize) !void {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    try allocator.?.free_page_block(page, num_pages);
}

pub fn is_page_free(page: u64) !bool {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    return allocator.?.is_page_free(page);
}
