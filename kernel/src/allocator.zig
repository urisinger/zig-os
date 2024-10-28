const std = @import("std");
const log = std.log;

const utils = @import("utils.zig");
const hang = utils.hang;

const limine = @import("limine");

pub const BitmapAllocator = struct {
    bitmap_ptr: [*]u32,
    num_pages: usize,
    const Error = error{
        OutOfBounds,
        NoFreePages,
        InvalidOperation,
    };

    pub fn allocatePage(self: *BitmapAllocator) !*void {
        const bitmap_size = (self.num_pages + 31) / 32;

        for (0.., self.bitmap_ptr[0..bitmap_size]) |word_index, *word| {
            if (word.* == 0) continue;

            const bit_index = @ctz(word.*);
            word.* &= ~(@as(u32, 1) << @intCast(bit_index));

            const page_ptr = @as(*void, @ptrFromInt(((word_index * 32) + bit_index) * utils.PAGE_SIZE));
            log.info("Allocated page at index: {}", .{(word_index * 32) + bit_index});
            return page_ptr;
        }

        std.log.err("Failed to allocate page: No free pages available", .{});
        return Error.NoFreePages;
    }

    pub fn freePage(self: *BitmapAllocator, page: *void) !void {
        const page_index = @intFromPtr(page) / utils.PAGE_SIZE;
        if (page_index >= self.num_pages) {
            log.err("Attempted to free an out-of-bounds page: {}", .{page_index});
            return Error.OutOfBounds;
        }

        const word_index = page_index / 32;
        const bit_index = page_index % 32;

        self.bitmap_ptr[word_index] |= @as(u32, 1) << @intCast(bit_index);
        std.log.info("Freed page at index: {}", .{page_index});
    }

    pub fn allocatePageBlock(self: *BitmapAllocator, num_pages: usize) !*void {
        if (num_pages == 0) return Error.InvalidOperation;

        const bitmap_size = (self.num_pages + 31) / 32;
        var remaining_pages: usize = 0;
        var start_page: usize = 0;

        for (0.., self.bitmap_ptr[0..bitmap_size]) |word_index, *word| {
            for (0..32) |bit_position| {
                if (word_index * 32 + bit_position >= self.num_pages) {
                    log.err("Failed to allocate block: No free pages available", .{});
                    return Error.NoFreePages;
                }

                if (word.* & (@as(u32, 1) << @intCast(bit_position)) != 0) {
                    if (remaining_pages == num_pages) {
                        start_page = (word_index * 32 + bit_position);
                    }
                    remaining_pages -= 1;

                    if (remaining_pages == 0) {
                        for (0..num_pages) |current_page| {
                            const word_idx = current_page / 32;
                            const bit_idx = current_page % 32;
                            self.bitmap_ptr[word_idx] &= ~(@as(u32, 1) << @intCast(bit_idx));
                        }
                        log.info("Allocated block of {} pages starting at index: {}", .{ num_pages, start_page });
                        return @ptrFromInt(start_page * utils.PAGE_SIZE);
                    }
                } else {
                    remaining_pages = num_pages;
                }
            }
        }

        log.err("Failed to allocate block: No contiguous free pages available", .{});
        return Error.NoFreePages;
    }

    pub fn freePageBlock(self: *BitmapAllocator, page: *void, num_pages: usize) !void {
        const block_start = @intFromPtr(page) / utils.PAGE_SIZE;
        if (block_start >= self.num_pages) {
            log.err("Attempted to free an out-of-bounds block starting at index: {}", .{block_start});
            return Error.OutOfBounds;
        }

        for (block_start..block_start + num_pages) |page_index| {
            const word_index = page_index / 32;
            const bit_index = page_index % 32;

            self.bitmap_ptr[word_index] |= (@as(u32, 1) << @intCast(bit_index));
        }

        log.info("Freed block of {} pages starting at index: {}", .{ num_pages, block_start });
    }

    pub fn isPageFree(self: *BitmapAllocator, page: *void) !bool {
        const page_index = @intFromPtr(page) / utils.PAGE_SIZE;
        if (page_index >= self.num_pages) {
            log.err("Checked status of an out-of-bounds page: {}", .{page_index});
            return Error.OutOfBounds;
        }

        const word_index = page_index / 32;
        const bit_index = page_index % 32;

        return (self.bitmap_ptr[word_index] & (1 << bit_index)) != 0;
    }
};

pub fn init(mem_map_response: *limine.MemoryMapResponse, offset: u64) !BitmapAllocator {
    const mem_map = mem_map_response.entries_ptr[0..mem_map_response.entry_count];
    var num_pages: usize = 0;
    log.info("enumarating {} memory entries", .{mem_map.len});

    for (0.., mem_map) |i, mem_entry| {
        num_pages += @divExact(mem_entry.length, utils.PAGE_SIZE);

        log.info("mem entry {}: ", .{i});
        log.info("type: {s}", .{@tagName(mem_entry.kind)});
        log.info("num_pages: {}", .{mem_entry.base / utils.PAGE_SIZE});
        log.info("first_page: {}\n", .{mem_entry.length / utils.PAGE_SIZE});
    }

    const bitmap_size = (num_pages + 31) / 32;
    const bitmap_bytes = bitmap_size * 4;
    const bitmap_num_pages = (bitmap_bytes + utils.PAGE_SIZE - 1) / utils.PAGE_SIZE;

    log.info("num_pages: {}", .{num_pages});
    log.info("bitmap_size: {}", .{bitmap_size});
    log.info("bitmap_bytes: {}", .{bitmap_bytes});
    log.info("bitmap_pages: {}", .{bitmap_num_pages});

    var bitmap_page: u64 = 0;
    for (mem_map) |mem_entry| {
        if (mem_entry.kind == .usable and mem_entry.length > bitmap_num_pages * utils.PAGE_SIZE) {
            bitmap_page = @divExact(mem_entry.base, utils.PAGE_SIZE);
            break;
        }
    }

    log.info("bitmap_page: {}", .{bitmap_page});

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

    log.info("bitmaps succsefully initialized ", .{});

    return BitmapAllocator{ .bitmap_ptr = bitmap_vaddr, .num_pages = num_pages };
}
