const std = @import("std");
const log = std.log.scoped(.buddy);
const utils = @import("../utils.zig");

/// Represents the minimum block size (4KB - page size)
pub const MIN_BLOCK_SIZE = utils.PAGE_SIZE;
const LOG_BLOCK_SIZE = std.math.log2_int(usize, MIN_BLOCK_SIZE);
/// Maximum order of blocks (2^MAX_ORDER * MIN_BLOCK_SIZE = maximum block size)
pub const MAX_ORDER = 10; // Supports up to 4MB blocks

pub const Error = error{
    OutOfMemory,
    InvalidSize,
    InvalidAddress,
    NotInitialized,
};

/// The BitmapBuddy allocator manages memory blocks of different sizes using a bitmap
pub const BitmapBuddyAllocator = struct {
    // Bitmap arrays for each order
    bitmaps: [MAX_ORDER + 1][]u32,
    // Number of pages available (total memory size / page size)
    num_pages: usize,
    // Maximum order available
    max_order: usize,

    /// Initialize a new buddy allocator with the given memory region
    pub fn init(bitmap_ptr: [*]u32, bitmap_size: usize, memory_size: usize) !BitmapBuddyAllocator {
        if (memory_size < MIN_BLOCK_SIZE) {
            return Error.InvalidSize;
        }

        // Calculate the number of pages
        const num_pages = memory_size / MIN_BLOCK_SIZE;
        // Calculate the maximum order based on memory size
        const max_order = getOrder(memory_size);

        // Initialize the allocator
        var allocator = BitmapBuddyAllocator{
            .bitmaps = undefined,
            .num_pages = num_pages,
            .max_order = max_order,
        };

        // Calculate and assign bitmap pointers for each order
        var bitmap_offset: usize = 0;
        var order: usize = 0;
        while (order <= max_order) : (order += 1) {
            // Calculate number of blocks at this order
            const blocks_at_order = num_pages >> @intCast(order);
            // Calculate bitmap size in u32s
            const bitmap_u32s = (blocks_at_order + 31) / 32;

            if ((bitmap_offset + bitmap_u32s) * 4 > bitmap_size) {
                log.err("Bitmap too small for allocator", .{});
                return Error.OutOfMemory;
            }

            // Assign the bitmap
            allocator.bitmaps[order] = bitmap_ptr[bitmap_offset .. bitmap_offset + bitmap_u32s];
            bitmap_offset += bitmap_u32s;
        }

        // Initialize all blocks as free
        order = 0;
        while (order <= max_order) : (order += 1) {
            // Set all bits to 1 (indicating free blocks)
            @memset(allocator.bitmaps[order], 0);
        }

        // Mark all blocks at max_order as allocated except the first one
        const max_bitmap = allocator.bitmaps[max_order];
        @memset(max_bitmap, 0xFFFFFFFF);

        return allocator;
    }

    pub fn getBitmapSize(size: usize) usize {
        const num_pages = size / MIN_BLOCK_SIZE;
        const max_order = getOrder(size);
        var order: usize = 0;
        var bitmap_offset: usize = 0;
        while (order <= max_order) : (order += 1) {
            // Calculate number of blocks at this order
            const blocks_at_order = num_pages >> @intCast(order);
            // Calculate bitmap size in u32s
            const bitmap_u32s = (blocks_at_order + 31) / 32;

            bitmap_offset += bitmap_u32s;
        }

        return bitmap_offset * 4;
    }

    pub fn getOrder(size: usize) usize {
        return @min(MAX_ORDER, std.math.log2_int(usize, size) - LOG_BLOCK_SIZE);
    }

    /// Check if a bit is set in the bitmap
    fn isBitSet(bitmap: []u32, bit_index: usize) bool {
        const word_index = bit_index / 32;
        const bit_pos = bit_index % 32;
        return (bitmap[word_index] & (@as(u32, 1) << @intCast(bit_pos))) != 0;
    }

    /// Set a bit in the bitmap
    fn setBit(bitmap: []u32, bit_index: usize) void {
        const word_index = bit_index / 32;
        const bit_pos = bit_index % 32;
        bitmap[word_index] |= (@as(u32, 1) << @intCast(bit_pos));
    }

    /// Clear a bit in the bitmap
    fn clearBit(bitmap: []u32, bit_index: usize) void {
        const word_index = bit_index / 32;
        const bit_pos = bit_index % 32;
        bitmap[word_index] &= ~(@as(u32, 1) << @intCast(bit_pos));
    }

    /// Get the buddy index of a block
    fn getBuddyIndex(block_index: usize) usize {
        return block_index ^ 1;
    }

    /// Check if a block is available at a specific order
    fn isBlockFree(self: *BitmapBuddyAllocator, order: usize, block_index: usize) bool {
        if (order > self.max_order or block_index >= (self.num_pages >> @intCast(@min(order, 63)))) {
            return false;
        }
        return isBitSet(self.bitmaps[order], block_index);
    }

    /// Mark a block as used
    fn markBlockUsed(self: *BitmapBuddyAllocator, order: usize, block_index: usize) void {
        if (order > self.max_order or block_index >= (self.num_pages >> @intCast(@min(order, 63)))) {
            return;
        }
        clearBit(self.bitmaps[order], block_index);
    }

    /// Mark a block as free
    fn markBlockFree(self: *BitmapBuddyAllocator, order: usize, block_index: usize) void {
        if (order > self.max_order or block_index >= (self.num_pages >> @intCast(@min(order, 63)))) {
            return;
        }
        setBit(self.bitmaps[order], block_index);
    }

    /// Find the first free block at a given order
    fn findFreeBlock(self: *BitmapBuddyAllocator, order: usize) ?usize {
        const bitmap = self.bitmaps[order];

        for (0..bitmap.len) |word_index| {
            const word = bitmap[word_index];
            if (word == 0) continue;

            const bit_index = @ctz(word);
            const block_index = word_index * 32 + bit_index;

            // Check if this block is within bounds
            if (block_index >= (self.num_pages >> @intCast(@min(order, 63)))) {
                return null;
            }

            return block_index;
        }

        return null;
    }

    /// Allocate a block of the given order
    pub fn allocateBlock(self: *BitmapBuddyAllocator, order: usize) ?usize {
        if (order > self.max_order) {
            return null;
        }

        // Try to find a block at the requested order
        if (self.findFreeBlock(order)) |block_index| {
            self.markBlockUsed(order, block_index);
            return block_index;
        }

        // If not found, try to split a larger block
        var higher_order = order + 1;
        while (higher_order <= self.max_order) : (higher_order += 1) {
            if (self.allocateBlock(higher_order)) |parent_index| {
                // Split the block
                const child_index = parent_index * 2;
                // Mark both children as free initially
                self.markBlockFree(order, child_index);
                self.markBlockFree(order, child_index + 1);
                // Mark the first child as used and return it
                self.markBlockUsed(order, child_index);
                return child_index;
            }
        }

        return null;
    }

    /// Try to merge buddy blocks recursively
    fn tryMergeBlocks(self: *BitmapBuddyAllocator, order: usize, block_index: usize) void {
        if (order >= self.max_order) {
            return;
        }

        const buddy_index = getBuddyIndex(block_index);

        // If buddy is also free, merge them
        if (self.isBlockFree(order, buddy_index)) {
            // Mark both blocks as used (we'll mark the parent as free)
            self.markBlockUsed(order, block_index);
            self.markBlockUsed(order, buddy_index);

            // Mark parent as free
            const parent_index = block_index / 2;
            self.markBlockFree(order + 1, parent_index);

            // Try to merge at the higher level
            self.tryMergeBlocks(order + 1, parent_index);
        }
    }

    pub fn freeBlock(self: *BitmapBuddyAllocator, block_index: usize, order: usize) !void {
        self.markBlockFree(order, block_index);

        // Try to merge with buddy
        self.tryMergeBlocks(order, block_index);
    }

    /// Mark a memory region as allocated, even if it spans multiple blocks
    pub fn markRegionAllocated(self: *BitmapBuddyAllocator, address: usize, end: usize) !void {
        // Iterate over orders from largest to smallest
        var order: usize = self.max_order;
        while (order > 0) : (order -= 1) {
            const block_size = (@as(usize, 1) << @intCast(order)) * MIN_BLOCK_SIZE;

            var offset = std.mem.alignBackward(usize, address, block_size);
            const end_offset = std.mem.alignForward(usize, end, block_size);

            while (offset < end_offset) {
                if (order == 0) {
                    std.log.info("Marking block at 0x{x}", .{offset});
                }
                const block_index = offset / block_size;

                if (block_index >= (self.num_pages >> @intCast(order))) {
                    return Error.InvalidAddress;
                }

                self.markBlockUsed(order, block_index);

                offset += block_size;
            }
        }
    }
};
