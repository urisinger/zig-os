const std = @import("std");
const log = std.log.scoped(.slab);
const kheap = @import("heap.zig");
const pmm = @import("../pmm.zig");
const utils = @import("../../utils.zig");

var slab_cache: ?*SlabCache = null;

var top_slab_cache: SlabCache = null;

pub fn get_slab_cache(obj_size: usize) !*SlabCache {
    // First check if we already have a cache for this size
    var current = top_slab_cache;
    while (current) |cache| {
        if (cache.obj_size == obj_size) {
            return cache;
        }
        current = cache.next;
    }

    // No existing cache found, create a new one
    const new_cache: *SlabCache = @ptrCast(@alignCast(top_slab_cache.allocate()));
    new_cache.* = SlabCache.init(obj_size, std.math.max(4, // Minimum 4 objects per slab
        utils.PAGE_SIZE / obj_size // Or as many as fit in a page
    ));

    // Insert at the head of the list
    new_cache.next = top_slab_cache;
    top_slab_cache = new_cache;

    return new_cache;
}

/// A slab is a contiguous region of memory divided into fixed-size objects
pub const Slab = struct {
    // Memory region for this slab
    memory: []u8,
    // Bitmap tracking which objects are allocated
    free_bitmap: []u8,
    // Number of objects currently allocated
    inuse: usize,
    // Total number of objects in this slab
    total: usize,
    // Size of each object
    obj_size: usize,
    // Next slab in the list
    next: ?*Slab,

    pub fn init(memory: []u8, obj_size: usize) !*Slab {
        const bitmap_start = @sizeOf(Slab);
        const len = memory.len - bitmap_start;

        const total_objects = len / obj_size;
        const bitmap_size = (total_objects + 7) / 8;

        if (len < bitmap_size + obj_size) {
            return error.SlabTooSmall;
        }

        // Use the first part of memory for the bitmap
        const bitmap = memory[bitmap_start .. bitmap_start + bitmap_size];
        // Clear the bitmap (1 means free)
        @memset(bitmap, 0xFF);

        return @ptrCast(@alignCast(memory.ptr));
    }

    pub fn allocate(self: *Slab) ?[*]u8 {
        if (self.inuse >= self.total) return null;

        // Find first free object using the bitmap
        var byte_index: usize = 0;
        while (byte_index < self.free_bitmap.len) : (byte_index += 1) {
            const byte = self.free_bitmap[byte_index];
            if (byte == 0) continue;

            // Find the first set bit
            const bit_index = @ctz(byte);
            if (bit_index >= 8) continue;

            const obj_index = byte_index * 8 + bit_index;
            if (obj_index >= self.total) break;

            // Clear the bit to mark as allocated
            self.free_bitmap[byte_index] &= ~(@as(u8, 1) << @intCast(bit_index));
            self.inuse += 1;

            return @ptrCast(self.memory.ptr + obj_index * self.obj_size);
        }

        return null;
    }

    pub fn free(self: *Slab, ptr: [*]u8) bool {
        const addr = @intFromPtr(ptr);
        const base = @intFromPtr(self.memory.ptr);

        if (addr < base or addr >= base + self.memory.len) {
            return false;
        }

        const offset = addr - base;
        if (offset % self.obj_size != 0) {
            return false;
        }

        const obj_index = offset / self.obj_size;
        const byte_index = obj_index / 8;
        const bit_index: u3 = @intCast(obj_index % 8);

        // Check if already free
        if (self.free_bitmap[byte_index] & (@as(u8, 1) << bit_index) != 0) {
            return false;
        }

        // Set the bit to mark as free
        self.free_bitmap[byte_index] |= (@as(u8, 1) << bit_index);
        self.inuse -= 1;
        return true;
    }

    pub fn isEmpty(self: *const Slab) bool {
        return self.inuse == 0;
    }

    pub fn isFull(self: *const Slab) bool {
        return self.inuse == self.total;
    }
};

/// A slab cache manages multiple slabs of the same object size
pub const SlabCache = struct {
    // Size of objects in this cache
    obj_size: usize,
    // Minimum number of objects per slab
    min_objects: usize,
    // List of partially used slabs
    partial_slabs: ?*Slab,
    // List of empty slabs
    free_slabs: ?*Slab,
    // List of full slabs
    full_slabs: ?*Slab,
    // Total number of objects allocated
    total_allocated: usize,
    // Next slab cache in the list
    next: ?*SlabCache,

    pub fn init(obj_size: usize, min_objects: usize) SlabCache {
        return SlabCache{
            .obj_size = obj_size,
            .min_objects = min_objects,
            .partial_slabs = null,
            .free_slabs = null,
            .full_slabs = null,
            .total_allocated = 0,
        };
    }

    pub fn allocate(self: *SlabCache) !*anyopaque {
        // Try partial slabs first
        if (self.partial_slabs) |slab| {
            if (slab.allocate()) |ptr| {
                self.total_allocated += 1;
                if (slab.isFull()) {
                    // Move to full list
                    self.partial_slabs = slab.next;
                    slab.next = self.full_slabs;
                    self.full_slabs = slab;
                }
                return @ptrCast(ptr);
            }
        }

        // Try free slabs
        if (self.free_slabs) |slab| {
            if (slab.allocate()) |ptr| {
                self.total_allocated += 1;
                // Move to partial list
                self.free_slabs = slab.next;
                slab.next = self.partial_slabs;
                self.partial_slabs = slab;
                return @ptrCast(ptr);
            }
        }

        // Need to create a new slab
        const slab_size = std.math.max(
            self.min_objects * self.obj_size,
            utils.PAGE_SIZE,
        );

        // Calculate the best order for allocation
        const pages_needed = (slab_size + utils.PAGE_SIZE - 1) / utils.PAGE_SIZE;
        const order = pmm.getOrder(pages_needed);

        // Allocate memory using the buddy allocator
        const memory_addr = try pmm.allocatePageBlock(order);
        const memory = @as([*]u8, @ptrFromInt(memory_addr))[0..slab_size];

        const new_slab = try Slab.init(memory, self.obj_size);
        new_slab.* = new_slab;

        // Add to partial list and allocate
        new_slab.next = self.partial_slabs;
        self.partial_slabs = new_slab;

        if (new_slab.allocate()) |ptr| {
            self.total_allocated += 1;
            return @ptrCast(ptr);
        }

        return error.SlabAllocationFailed;
    }

    pub fn free(self: *SlabCache, ptr: *anyopaque) bool {
        // Try partial slabs
        var current = self.partial_slabs;
        const prev: ?*Slab = null;

        while (current) |slab| {
            if (slab.free(@ptrCast(ptr))) {
                if (slab.isEmpty()) {
                    // Move to free list
                    if (prev) |p| {
                        p.next = slab.next;
                    } else {
                        self.partial_slabs = slab.next;
                    }
                    slab.next = self.free_slabs;
                    self.free_slabs = slab;
                }
                self.total_allocated -= 1;
                return true;
            }
            prev = slab;
            current = slab.next;
        }

        // Try full slabs
        current = self.full_slabs;
        const prev2: ?*Slab = null;

        while (current) |slab| {
            if (slab.free(@ptrCast(ptr))) {
                // Move to partial list
                if (prev2) |p| {
                    p.next = slab.next;
                } else {
                    self.full_slabs = slab.next;
                }
                slab.next = self.partial_slabs;
                self.partial_slabs = slab;
                self.total_allocated -= 1;
                return true;
            }
            prev2 = slab;
            current = slab.next;
        }

        return false;
    }

    pub fn deinit(self: *SlabCache, allocator: std.mem.Allocator) void {
        // Free all slabs
        const lists = [_]?*Slab{
            self.partial_slabs,
            self.free_slabs,
            self.full_slabs,
        };

        for (lists) |list| {
            var current = list;
            while (current) |slab| {
                const next = slab.next;
                const pages = (slab.memory.len + utils.PAGE_SIZE - 1) / utils.PAGE_SIZE;
                const order = pmm.getOrder(pages);
                pmm.freePageBlock(@intFromPtr(slab.memory.ptr), order) catch {};
                allocator.destroy(slab);
                current = next;
            }
        }

        self.* = undefined;
    }
};
