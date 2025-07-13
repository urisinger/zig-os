const std = @import("std");
const log = std.log.scoped(.pmm);

const utils = @import("../utils.zig");

const limine = @import("limine");

const globals = @import("../globals.zig");
const boot = @import("../boot.zig");
const Bitmap = @import("../structs/bitmap.zig").Bitmap;

pub const Error = error{
    OutOfMemory,
    NotInitialized,
};

var bitmap: ?Bitmap = undefined;

pub fn setBlockAllocated(addr: u64) !void {
    if (bitmap == null) {
        log.err("Bitmap is not initialized", .{});
        return Error.NotInitialized;
    }
    const block_index = @divExact(addr, utils.PAGE_SIZE);
    if (block_index >= bitmap.?.size) {
        return;
    }
    bitmap.?.clear(block_index);
}

pub fn allocatePage() !u64 {
    if (bitmap == null) {
        log.err("Bitmap is not initialized", .{});
        return Error.NotInitialized;
    }
    const block_index = bitmap.?.findFirstSet() orelse return Error.OutOfMemory;
    bitmap.?.clear(block_index);

    return block_index * utils.PAGE_SIZE;
}

pub fn freePage(page: u64) !void {
    if (bitmap == null) {
        log.err("Bitmap is not initialized", .{});
        return Error.NotInitialized;
    }
    const block_index = @divExact(page, utils.PAGE_SIZE);
    bitmap.?.set(block_index);
}

pub fn allocatePageBlock(num_pages: usize, page_alignment: std.mem.Alignment) !u64 {
    if (bitmap == null) {
        log.err("Bitmap is not initialized", .{});
        return Error.NotInitialized;
    }

    // Find aligned block of pages
    const page = bitmap.?.findFirstNSetAligned(num_pages, page_alignment) orelse {
        log.err("Could not find {d} aligned pages", .{num_pages});
        return Error.OutOfMemory;
    };

    // Verify the block is actually free
    for (page..page + num_pages) |i| {
        if (!bitmap.?.get(i)) {
            log.err("Found block at {d} but it's not fully free", .{page});
            return Error.OutOfMemory;
        }
    }

    // Mark the block as allocated
    bitmap.?.clearRange(page, page + num_pages);

    // Calculate and verify the final address
    if (page % (page_alignment.toByteUnits()) != 0) {
        log.err("page {x} is not properly aligned to {d}", .{ page, page_alignment.toByteUnits() });
        return Error.OutOfMemory;
    }

    const addr = page * utils.PAGE_SIZE;

    return addr;
}

pub fn freePageBlock(page: u64, num_pages: usize) !void {
    if (bitmap == null) {
        log.err("Bitmap is not initialized", .{});
        return Error.NotInitialized;
    }

    const block_index = @divExact(page, utils.PAGE_SIZE);
    bitmap.?.setRange(block_index, block_index + num_pages);
}

pub fn init() !void {
    const mem_map = boot.params.?.memory_map;
    const offset = globals.hhdm_offset;

    var max_addr: u64 = 0;

    // First pass: find max address and calculate bitmap size
    for (mem_map) |mem_entry| {
        if (mem_entry.kind != .usable) {
            continue;
        }

        const end_addr = mem_entry.base + mem_entry.length;
        if (end_addr > max_addr) {
            max_addr = end_addr;
        }
    }

    const num_pages: usize = std.mem.alignForward(u64, max_addr, utils.PAGE_SIZE) / utils.PAGE_SIZE;
    const bitmap_u64s: usize = Bitmap.getBitmapSize(num_pages);
    const bitmap_num_pages = std.math.divCeil(u64, bitmap_u64s * 8, utils.PAGE_SIZE) catch unreachable;

    // Second pass: find a suitable location for the bitmap
    var bitmap_page: u64 = 0;
    var bitmap_found = false;
    for (mem_map) |mem_entry| {
        if (mem_entry.kind == .usable) {
            const entry_pages = std.math.divCeil(u64, mem_entry.length, utils.PAGE_SIZE) catch unreachable;
            if (entry_pages >= bitmap_num_pages) {
                bitmap_page = @divExact(mem_entry.base, utils.PAGE_SIZE);
                bitmap_found = true;
                break;
            }
        }
    }

    if (!bitmap_found) {
        log.err("Could not find suitable location for bitmap", .{});
        return error.OutOfMemory;
    }

    const bitmap_vaddr: [*]u64 = @ptrFromInt(bitmap_page * utils.PAGE_SIZE + offset);

    // Initialize bitmap - start with all pages marked as used (0)
    bitmap = try Bitmap.init(bitmap_vaddr[0..bitmap_u64s], num_pages);
    bitmap.?.setAll(); // Set all bits to 1 (free)

    // Third pass: mark all usable memory as free (1)
    for (mem_map) |mem_entry| {
        if (mem_entry.kind == .usable) {
            const start_page = std.math.divFloor(u64, mem_entry.base, utils.PAGE_SIZE) catch unreachable;
            const end_page = std.math.divCeil(u64, mem_entry.base + mem_entry.length, utils.PAGE_SIZE) catch unreachable;
            bitmap.?.setRange(start_page, end_page); // Mark as free (1)
        }
    }

    // Fourth pass: mark unusable regions as used (0)
    for (mem_map) |mem_entry| {
        if (mem_entry.kind != .usable) {
            const start_page = std.math.divFloor(u64, mem_entry.base, utils.PAGE_SIZE) catch unreachable;
            const end_page = std.math.divCeil(u64, mem_entry.base + mem_entry.length, utils.PAGE_SIZE) catch unreachable;
            bitmap.?.clearRange(start_page, end_page); // Mark as used (0)
        }
    }

    // Finally, mark the bitmap region itself as used (0)
    bitmap.?.clearRange(bitmap_page, bitmap_page + bitmap_num_pages);

    log.info("initialized pmm with {d} pages", .{num_pages});
}
