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
    return (allocator.?.allocateBlock(order) orelse return Error.OutOfMemory) * utils.PAGE_SIZE;
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
            std.log.info("Skipping unusable region at 0x{x} with size 0x{x}", .{ mem_entry.base, mem_entry.length });
            continue;
        }

        const end_addr = mem_entry.base + mem_entry.length;
        if (end_addr > max_addr) {
            max_addr = end_addr;
        }
    }

    std.log.info("Max address: 0x{x}", .{max_addr});

    const num_pages: usize = std.mem.alignForward(u64, max_addr, utils.PAGE_SIZE) / utils.PAGE_SIZE;

    // Calculate bitmap size for the buddy allocator
    // Each order has a different number of blocks:
    // - Order 0: num_pages blocks
    // - Order 1: num_pages/2 blocks
    // - Order 2: num_pages/4 blocks
    // etc.
    const bitmap_bytes: usize = BuddyAllocator.getBitmapSize(num_pages * utils.PAGE_SIZE);
    const bitmap_num_pages = std.math.divCeil(u64, bitmap_bytes, utils.PAGE_SIZE) catch unreachable;

    // Find a memory region to place the bitmap
    var bitmap_page: u64 = 0;
    for (mem_map) |mem_entry| {
        if (mem_entry.type == .usable and mem_entry.length > bitmap_num_pages * utils.PAGE_SIZE) {
            bitmap_page = @divExact(mem_entry.base, utils.PAGE_SIZE);
            break;
        }
    }

    const bitmap_vaddr: [*]u8 = @ptrFromInt(bitmap_page * utils.PAGE_SIZE + offset);

    // Initialize bitmap memory as all zeroes
    @memset(bitmap_vaddr[0..bitmap_bytes], 0);

    // Initialize buddy allocator
    var buddy = try BuddyAllocator.init(@as([*]u32, @alignCast(@ptrCast(bitmap_vaddr)))[0..bitmap_bytes], num_pages * utils.PAGE_SIZE);

    // Mark all unusable regions as allocated in the buddy allocator
    for (mem_map) |mem_entry| {
        if (mem_entry.type != .usable) {
            if (mem_entry.base + mem_entry.length > max_addr) {
                std.log.info("Skipping unusable region at 0x{x} with size 0x{x}", .{ mem_entry.base, mem_entry.length });
                continue;
            }

            // Mark as allocated in buddy system
            const start_addr = std.mem.alignBackward(u64, mem_entry.base, utils.PAGE_SIZE);
            const end_addr = std.mem.alignForward(u64, mem_entry.base + mem_entry.length, utils.PAGE_SIZE);
            const region_size = end_addr - start_addr;

            std.log.info("Marking unusable region at 0x{x} with size 0x{x}", .{ start_addr, region_size });

            buddy.markRegionAllocated(start_addr, region_size) catch |err| {
                log.err("Failed to mark unusable region at 0x{x} with size 0x{x}: {}", .{ start_addr, region_size, err });
            };
        }
    }

    // Also mark the bitmap region itself as allocated
    const bitmap_addr = bitmap_page * utils.PAGE_SIZE;
    const bitmap_size = bitmap_num_pages * utils.PAGE_SIZE;

    std.log.info("Marking bitmap region at 0x{x} with size 0x{x}", .{ bitmap_addr, bitmap_size });

    buddy.markRegionAllocated(bitmap_addr, bitmap_size) catch |err| {
        log.err("Failed to mark bitmap region at 0x{x} with size 0x{x}: {}", .{ bitmap_addr, bitmap_size, err });
    };

    allocator = buddy;
    log.info("initialized pmm with buddy allocator", .{});
}

// Helper function to find largest power of 2 that is less than or equal to n
fn largestPowerOf2LessOrEqual(n: u64) u64 {
    if (n == 0) return 0;
    var power: u6 = 0;
    while ((@as(u64, 1) << (power + 1)) <= n) {
        power += 1;
    }
    return @as(u64, 1) << power;
}
