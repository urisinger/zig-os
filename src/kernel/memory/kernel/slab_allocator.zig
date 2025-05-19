const std = @import("std");
const log = std.log.scoped(.slab_allocator);
const slab = @import("slab.zig");
const utils = @import("../../utils.zig");

/// A slab allocator that uses slab caches for efficient object allocation
pub const SlabAllocator = struct {
    // Cache for small objects (<= 64 bytes)
    small_cache: ?*slab.SlabCache,
    // Cache for medium objects (<= 256 bytes)
    medium_cache: ?*slab.SlabCache,
    // Cache for large objects (<= 1024 bytes)
    large_cache: ?*slab.SlabCache,
    // Cache for very large objects (<= 4096 bytes)
    xlarge_cache: ?*slab.SlabCache,
    // Fallback allocator for objects larger than 4096 bytes
    fallback_allocator: std.mem.Allocator,

    pub fn init(fallback_allocator: std.mem.Allocator) !SlabAllocator {
        return SlabAllocator{
            .small_cache = try slab.get_slab_cache(64),
            .medium_cache = try slab.get_slab_cache(256),
            .large_cache = try slab.get_slab_cache(1024),
            .xlarge_cache = try slab.get_slab_cache(4096),
            .fallback_allocator = fallback_allocator,
        };
    }

    pub fn deinit(self: *SlabAllocator) void {
        if (self.small_cache) |cache| {
            cache.deinit(self.fallback_allocator);
        }
        if (self.medium_cache) |cache| {
            cache.deinit(self.fallback_allocator);
        }
        if (self.large_cache) |cache| {
            cache.deinit(self.fallback_allocator);
        }
        if (self.xlarge_cache) |cache| {
            cache.deinit(self.fallback_allocator);
        }
    }

    fn getCacheForSize(self: *SlabAllocator, size: usize) ?*slab.SlabCache {
        if (size <= 64) return self.small_cache;
        if (size <= 256) return self.medium_cache;
        if (size <= 1024) return self.large_cache;
        if (size <= 4096) return self.xlarge_cache;
        return null;
    }

    pub fn alloc(self: *SlabAllocator, size: usize, alignment: u8, len: usize, ret_addr: usize) ![]u8 {
        // Check if we can use a slab cache
        if (self.getCacheForSize(size)) |cache| {
            const ptr = try cache.allocate();
            return @as([*]u8, @ptrCast(ptr))[0..size];
        }

        // Fall back to the fallback allocator for larger objects
        return self.fallback_allocator.alloc(size, alignment, len, ret_addr);
    }

    pub fn resize(_: *SlabAllocator, buf: []u8, _: u8, new_size: usize, _: usize) ?usize {
        // If the new size is the same, no need to reallocate
        if (new_size == buf.len) return new_size;

        // If we're shrinking, just return the new size
        if (new_size < buf.len) return new_size;

        // For growing, we need to reallocate
        return null;
    }

    pub fn free(self: *SlabAllocator, buf: []u8, buf_align: u8, ret_addr: usize) void {
        // Try to free from each cache
        if (self.small_cache) |cache| {
            if (cache.free(@ptrCast(buf.ptr))) return;
        }
        if (self.medium_cache) |cache| {
            if (cache.free(@ptrCast(buf.ptr))) return;
        }
        if (self.large_cache) |cache| {
            if (cache.free(@ptrCast(buf.ptr))) return;
        }
        if (self.xlarge_cache) |cache| {
            if (cache.free(@ptrCast(buf.ptr))) return;
        }

        // If not found in any cache, use fallback allocator
        self.fallback_allocator.free(buf, buf_align, ret_addr);
    }
};

/// Create a new slab allocator instance
pub fn createSlabAllocator(fallback_allocator: std.mem.Allocator) !std.mem.Allocator {
    var allocator = try SlabAllocator.init(fallback_allocator);
    return std.mem.Allocator{
        .ptr = &allocator,
        .vtable = &vtable,
    };
}

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .free = free,
};

fn alloc(ctx: *anyopaque, size: usize, alignment: u8, len: usize, ret_addr: usize) ![]u8 {
    const self = @as(*SlabAllocator, @ptrCast(ctx));
    return self.alloc(size, alignment, len, ret_addr);
}

fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_size: usize, ret_addr: usize) ?usize {
    const self = @as(*SlabAllocator, @ptrCast(ctx));
    return self.resize(buf, buf_align, new_size, ret_addr);
}

fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
    const self = @as(*SlabAllocator, @ptrCast(ctx));
    self.free(buf, buf_align, ret_addr);
}

// Test the slab allocator
test "slab allocator basic functionality" {
    const testing = std.testing;
    const fallback = testing.allocator;

    var slab_allocator = try SlabAllocator.init(fallback);
    defer slab_allocator.deinit();

    // Test small allocation (<= 64 bytes)
    const small_buf = try slab_allocator.alloc(32, 8, 1, @returnAddress());
    defer slab_allocator.free(small_buf, 8, @returnAddress());
    try testing.expect(small_buf.len == 32);

    // Test medium allocation (<= 256 bytes)
    const medium_buf = try slab_allocator.alloc(128, 8, 1, @returnAddress());
    defer slab_allocator.free(medium_buf, 8, @returnAddress());
    try testing.expect(medium_buf.len == 128);

    // Test large allocation (<= 1024 bytes)
    const large_buf = try slab_allocator.alloc(512, 8, 1, @returnAddress());
    defer slab_allocator.free(large_buf, 8, @returnAddress());
    try testing.expect(large_buf.len == 512);

    // Test very large allocation (<= 4096 bytes)
    const xlarge_buf = try slab_allocator.alloc(2048, 8, 1, @returnAddress());
    defer slab_allocator.free(xlarge_buf, 8, @returnAddress());
    try testing.expect(xlarge_buf.len == 2048);

    // Test fallback allocation (> 4096 bytes)
    const huge_buf = try slab_allocator.alloc(8192, 8, 1, @returnAddress());
    defer slab_allocator.free(huge_buf, 8, @returnAddress());
    try testing.expect(huge_buf.len == 8192);
}
