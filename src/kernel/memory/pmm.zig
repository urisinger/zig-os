const std = @import("std");
const log = std.log.scoped(.pmm);

const utils = @import("../utils.zig");

const limine = @import("limine");

const globals = @import("../globals.zig");
const boot = @import("../boot.zig");

const BuddyAllocator = @import("buddy.zig").BuddyAllocator;

pub const Error = error{
    OutOfMemory,
    NotInitialized,
};
var allocator: ?BuddyAllocator = null;

pub fn getOrder(num_pages: usize) usize {
    return std.math.log2_int_ceil(usize, num_pages);
}

pub fn allocatePage() !u64 {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.NotInitialized;
    }
    const block_index = allocator.?.allocateBlock(0) orelse return Error.OutOfMemory;
    return block_index * utils.PAGE_SIZE;
}

pub fn freePage(page: u64) !void {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.NotInitialized;
    }
    const block_index = @divExact(page, utils.PAGE_SIZE);
    try allocator.?.freeBlock(block_index, 0);
}

pub fn allocatePageBlock(order: usize) !u64 {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.NotInitialized;
    }
    const addr = (allocator.?.allocateBlock(order) orelse return Error.OutOfMemory) * utils.PAGE_SIZE;

    return addr;
}

pub fn freePageBlock(page: u64, order: usize) !void {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.NotInitialized;
    }

    const block_index = @divExact(page, utils.PAGE_SIZE);
    try allocator.?.freeBlock(block_index, order);
}

pub fn init() !void {
    const mem_map = boot.params.?.memory_map;
    const offset = globals.hhdm_offset;

    var max_addr: u64 = 0;

    for (mem_map) |mem_entry| {
        if (mem_entry.type != .usable) {
            continue;
        }

        const end_addr = mem_entry.base + mem_entry.length;
        if (end_addr > max_addr) {
            max_addr = end_addr;
        }
    }

    const num_pages: usize = std.mem.alignForward(u64, max_addr, utils.PAGE_SIZE) / utils.PAGE_SIZE;

    // Calculate bitmap size for the buddy allocator
    // Each order has a different number of blocks:
    // - Order 0: num_pages blocks
    // - Order 1: num_pages/2 blocks
    // - Order 2: num_pages/4 blocks
    // etc.
    const bitmap_u32s: usize = BuddyAllocator.getBitmapSize(num_pages * utils.PAGE_SIZE);
    const bitmap_num_pages = std.math.divCeil(u64, bitmap_u32s * 4, utils.PAGE_SIZE) catch unreachable;

    // Find a memory region to place the bitmap
    var bitmap_page: u64 = 0;
    for (mem_map) |mem_entry| {
        if (mem_entry.type == .usable and std.math.divCeil(u64, mem_entry.length, utils.PAGE_SIZE) catch unreachable > bitmap_num_pages) {
            bitmap_page = @divExact(mem_entry.base, utils.PAGE_SIZE);
            break;
        }
    }

    const bitmap_vaddr: [*]u32 = @ptrFromInt(bitmap_page * utils.PAGE_SIZE + offset);

    // Initialize buddy allocator
    var buddy = try BuddyAllocator.init(bitmap_vaddr[0..bitmap_u32s], num_pages * utils.PAGE_SIZE);

    // Mark all unusable regions as allocated in the buddy allocator
    for (mem_map) |mem_entry| {
        if (mem_entry.type != .usable) {
            if (mem_entry.base + mem_entry.length > max_addr) {
                continue;
            }

            // Mark as allocated in buddy system
            const start_addr = std.mem.alignBackward(u64, mem_entry.base, utils.PAGE_SIZE);
            const end_addr = std.mem.alignForward(u64, mem_entry.base + mem_entry.length, utils.PAGE_SIZE);

            buddy.markRegionAllocated(start_addr, end_addr) catch |err| {
                log.err("Failed to mark unusable region at 0x{x} with size 0x{x}: {} 0x{x}", .{ start_addr, end_addr, err, max_addr });
            };
        }
    }

    buddy.markRegionAllocated(bitmap_page * utils.PAGE_SIZE, (bitmap_page + bitmap_num_pages) * utils.PAGE_SIZE) catch |err| {
        log.err("Failed to mark bitmap region at 0x{x} with size 0x{x}: {}", .{ bitmap_page, bitmap_num_pages, err });
    };

    allocator = buddy;
    log.info("initialized pmm with buddy allocator", .{});
}
