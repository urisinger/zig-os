const std = @import("std");
const log = std.log;

const utils = @import("../../utils.zig");
const globals = @import("../../globals.zig");

const pmm = @import("../pmm.zig");
const paging = @import("paging.zig");
const MmapFlags = paging.MmapFlags;

const BitmapAllocator = @import("../allocator.zig").BitmapAllocator;
const Error = @import("../allocator.zig").Error;

var allocator: ?BitmapAllocator = null;
var heap_start: u64 = undefined;

const heap_size = utils.GB(2);

pub fn init() !void {
    heap_start = std.mem.alignForward(u64, @intFromPtr(&globals.kernel_end), utils.PAGE_SIZE);

    const num_pages: usize = std.math.divCeil(u64, heap_size, utils.PAGE_SIZE) catch unreachable;
    const bitmap_size = (num_pages + 31) / 32;
    const bitmap_bytes = bitmap_size * 4;
    const bitmap_num_pages = try std.math.divCeil(u64, bitmap_bytes, utils.PAGE_SIZE);

    const alloc_start = heap_start;
    for (0..bitmap_num_pages) |_| {
        const paddr = try pmm.allocatePage();

        try paging.mapPage(@bitCast(heap_start), paddr, MmapFlags{
            .present = true,
            .read_write = .read_write,
        });

        heap_start += utils.PAGE_SIZE;
    }

    allocator = BitmapAllocator{
        .bitmap_ptr = @ptrFromInt(alloc_start),
        .num_pages = num_pages,
    };

    @memset(allocator.?.bitmap_ptr[0..bitmap_size], ~@as(u32, 0));

    log.info("initialized vmm", .{});
}

pub fn allocatePage() !u64 {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    return try allocator.?.allocatePage() + heap_start;
}

pub fn freePage(page: u64) !void {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    if (page < heap_start) {
        log.err("Attempt to free page before heap start: 0x{x}", .{page});
        return Error.OutOfBounds;
    }
    try allocator.?.freePage(page - heap_start);
}

pub fn allocatePageBlock(num_pages: usize) !u64 {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }

    const addr = try allocator.?.allocatePageBlock(num_pages) + heap_start;

    return addr;
}

pub fn freePageBlock(page: u64, num_pages: usize) !void {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    if (page < heap_start) {
        log.err("Attempt to free page block before heap start: 0x{x}", .{page});
        return Error.OutOfBounds;
    }
    try allocator.?.freePageBlock(page - heap_start, num_pages);
}
