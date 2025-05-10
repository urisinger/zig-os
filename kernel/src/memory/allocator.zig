const std = @import("std");
const log = std.log;

const globals = @import("../globals.zig");
const utils = @import("../utils.zig");

pub const Error = error{
    OutOfBounds,
    NoFreePages,
    InvalidOperation,
    AllocatorNotInitialized,
};

pub const BitmapAllocator = struct {
    bitmap_ptr: [*]u32,
    num_pages: usize,

    pub fn allocatePage(self: *BitmapAllocator) !u64 {
        const bitmap_size = (self.num_pages + 31) / 32;

        for (0.., self.bitmap_ptr[0..bitmap_size]) |word_index, *word| {
            if (word.* == 0) continue;

            const bit_index = @ctz(word.*);

            if (word_index * 32 + bit_index >= self.num_pages) {
                break;
            }
            word.* &= ~(@as(u32, 1) << @intCast(bit_index));

            const page_ptr = ((word_index * 32) + bit_index) * utils.PAGE_SIZE;
            return page_ptr;
        }

        std.log.err("Failed to allocate page: No free pages available", .{});
        return Error.NoFreePages;
    }

    pub fn freePage(self: *BitmapAllocator, page: u64) !void {
        const page_index = page / utils.PAGE_SIZE;
        if (page_index >= self.num_pages) {
            log.err("Attempted to free an out-of-bounds page: {}", .{page_index});
            return Error.OutOfBounds;
        }

        const word_index = page_index / 32;
        const bit_index = page_index % 32;

        self.bitmap_ptr[word_index] |= @as(u32, 1) << @intCast(bit_index);
    }

    pub fn allocatePageBlock(self: *BitmapAllocator, num_pages: usize) !u64 {
        if (num_pages == 0) return Error.InvalidOperation;

        const bitmap_size = (self.num_pages + 31) / 32;
        var remaining_pages: usize = num_pages;
        var start_page: usize = 0;

        for (0.., self.bitmap_ptr[0..bitmap_size]) |word_index, *word| {
            if (word.* == 0) continue;
            for (0..32) |bit_position| {
                if (word_index * 32 + bit_position >= self.num_pages) {
                    break;
                }

                if (word.* & (@as(u32, 1) << @intCast(bit_position)) != 0) {
                    remaining_pages -= 1;

                    if (remaining_pages == 0) {
                        for (start_page..start_page + num_pages) |current_page| {
                            const word_idx = current_page / 32;
                            const bit_idx = current_page % 32;

                            self.bitmap_ptr[word_idx] &= ~(@as(u32, 1) << @intCast(bit_idx));
                        }
                        return start_page * utils.PAGE_SIZE;
                    }
                } else {
                    remaining_pages = num_pages;
                    start_page = (word_index * 32 + bit_position + 1);
                }

            }
        }

        log.err("Failed to allocate block: No {} contiguous free pages available", .{num_pages});
        return Error.NoFreePages;
    }

    pub fn freePageBlock(self: *BitmapAllocator, page: u64, num_pages: usize) !void {
        const block_start = page / utils.PAGE_SIZE;
        if (block_start >= self.num_pages) {
            log.err("Attempted to free an out-of-bounds block starting at index: {}", .{block_start});
            return Error.OutOfBounds;
        }

        for (block_start..block_start + num_pages) |page_index| {
            const word_index = page_index / 32;
            const bit_index = page_index % 32;

            self.bitmap_ptr[word_index] |= (@as(u32, 1) << @intCast(bit_index));
        }
    }

    pub fn isPageFree(self: *BitmapAllocator, page: u64) !bool {
        const page_index = page / utils.PAGE_SIZE;
        if (page_index >= self.num_pages) {
            log.err("Checked status of an out-of-bounds page: {}", .{page_index});
            return Error.OutOfBounds;
        }

        const word_index = page_index / 32;
        const bit_index = page_index % 32;

        return (self.bitmap_ptr[word_index] & (1 << bit_index)) != 0;
    }

    pub fn unfreePage(self: *BitmapAllocator, page_index: u64) !void {
        if (page_index >= self.num_pages) {
            log.err("Checked status of an out-of-bounds page: {}", .{page_index});
            return Error.OutOfBounds;
        }

        const word_index = page_index / 32;
        const bit_index = page_index % 32;

        self.bitmap_ptr[word_index] &= ~(@as(u32, 1) << @intCast(bit_index));
    }
};
