const std = @import("std");
const log = std.log;

const utils = @import("../utils.zig");

const limine = @import("limine");

const globals = @import("../globals.zig");
const boot = @import("../boot.zig");

const BitmapAllocator = @import("allocator.zig").BitmapAllocator;
const Error = @import("allocator.zig").Error;

var allocator: ?BitmapAllocator = null;

pub fn allocatePage() !u64 {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    return allocator.?.allocatePage();
}

pub fn freePage(page: u64) !void {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    try allocator.?.freePage(page);
}

pub fn allocatePageBlock(num_pages: usize) !u64 {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    return allocator.?.allocatePageBlock(num_pages);
}

pub fn freePageBlock(page: u64, num_pages: usize) !void {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    try allocator.?.freePageBlock(page, num_pages);
}

pub fn isPageFree(page: u64) !bool {
    if (allocator == null) {
        log.err("Allocator is not initialized", .{});
        return Error.AllocatorNotInitialized;
    }
    return allocator.?.isPageFree(page);
}

pub fn init() !void {
    const mem_map = boot.params.?.memory_map;
    const offset = globals.hhdm_offset;

    const num_pages: usize = std.mem.alignForward(u64, globals.mem_size, utils.PAGE_SIZE) / utils.PAGE_SIZE;
    const bitmap_size = (num_pages + 31) / 32;
    const bitmap_bytes = bitmap_size * 4;
    const bitmap_num_pages = (bitmap_bytes + utils.PAGE_SIZE - 1) / utils.PAGE_SIZE;

    var bitmap_page: u64 = 0;
    for (mem_map) |mem_entry| {
        if (mem_entry.kind == .usable and mem_entry.length > bitmap_num_pages * utils.PAGE_SIZE) {
            bitmap_page = @divExact(mem_entry.base, utils.PAGE_SIZE);
            break;
        }
    }

    const bitmap_vaddr: [*]u32 = @alignCast(@ptrCast(@as([*]u8, @ptrFromInt(bitmap_page * utils.PAGE_SIZE)) + offset));

    for (mem_map) |mem_entry| {
        if (mem_entry.kind == .usable) {
            for (@divExact(mem_entry.base, utils.PAGE_SIZE)..@divExact(mem_entry.base + mem_entry.length, utils.PAGE_SIZE)) |page_index| {
                const int_index = page_index / 32;
                const bit_index = page_index % 32;

                bitmap_vaddr[int_index] |= (@as(u32, 1) << @intCast(bit_index));
            }
        }
    }

    for (bitmap_page..bitmap_page + bitmap_num_pages) |page_index| {
        const byte_index = page_index / 32;
        const bit_index = page_index % 32;

        bitmap_vaddr[byte_index] &= ~(@as(u32, 1) << @intCast(bit_index));
    }

    allocator = BitmapAllocator{ .bitmap_ptr = bitmap_vaddr, .num_pages = num_pages };

    log.info("initialized pmm", .{});
}
