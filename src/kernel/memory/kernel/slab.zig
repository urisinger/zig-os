const std = @import("std");
const log = std.log.scoped(.slab);
const kheap = @import("heap.zig");
const pmm = @import("../pmm.zig");
const utils = @import("../../utils.zig");
const globals = @import("../../globals.zig");
var top_slab_cache: ?SlabCache = null;

pub fn get_slab_cache(T: type) !SlabCacheTyped(T) {
    const obj_size = @sizeOf(T);
    // First check if we already have a cache for this size
    if (top_slab_cache == null) {
        top_slab_cache = SlabCache.init(@sizeOf(SlabCache), @max(4, Slab.max_objects(utils.PAGE_SIZE, @sizeOf(SlabCache))));
    }

    var current: ?*SlabCache = &top_slab_cache.?;
    while (current) |cache| {
        if (cache.obj_size == obj_size) {
            return .fromBase(cache);
        }

        if (cache.next == null) {
            break;
        }
        current = cache.next;
    }

    // No existing cache found, create a new one
    const new_cache: *SlabCache = @ptrCast(@alignCast(try top_slab_cache.?.allocate()));
    new_cache.* = SlabCache.init(
        obj_size,
        @max(4, Slab.max_objects(utils.PAGE_SIZE, obj_size)),
    );

    // Insert in order
    new_cache.next = current.?.next;
    current.?.next = new_cache;

    current = &top_slab_cache.?;
    while (current) |cache| {
        log.info("cache: {d}", .{cache.obj_size});
        current = cache.next;
    }

    return .fromBase(new_cache);
}

/// A slab is a contiguous region of memory divided into fixed-size objects
pub const Slab = struct {
    pub const FreeRegion = struct {
        next: ?*FreeRegion,
        magic: u32 = 0xDEADBEEF,
    };
    // Memory region for this slab
    memory: []u8,
    // Size of each object
    obj_size: usize,
    // Number of objects in use
    inuse: usize,
    // Next slab in the list
    next: ?*Slab,
    // Free regions in the slab
    free_list: ?*FreeRegion,

    pub fn max_objects(mem_size: usize, obj_size: usize) usize {
        return (mem_size - @sizeOf(Slab)) / obj_size;
    }

    pub fn init(memory: []u8, obj_size: usize) !*Slab {
        log.info("obj_size: {d}", .{obj_size});
        if (obj_size < @sizeOf(FreeRegion)) {
            return error.ObjectTooSmall;
        }

        const slab_start = std.mem.alignForward(usize, @sizeOf(Slab), @alignOf(Slab));
        if (memory.len < slab_start + obj_size) {
            return error.SlabTooSmall;
        }

        const slab: *Slab = @ptrCast(@alignCast(memory.ptr));
        slab.memory = memory[slab_start..];
        slab.obj_size = obj_size;
        slab.inuse = 0;
        slab.next = null;
        slab.free_list = null;

        // Build the free list in reverse order to maintain proper linking
        var mem_index: usize = slab.memory.len;
        while (mem_index >= obj_size) {
            mem_index -= obj_size;
            const region: *FreeRegion = @ptrCast(@alignCast(slab.memory.ptr + mem_index));

            region.magic = 0xDEADBEEF;
            region.next = slab.free_list;
            slab.free_list = region;
        }

        return slab;
    }

    pub fn allocate(self: *Slab) ?[*]u8 {
        if (self.free_list) |region| {
            if (region.magic != 0xDEADBEEF) {
                @panic("Slab corruption detected: invalid magic number");
            }
            self.free_list = region.next;
            self.inuse += 1;

            // Set the allocated region magic
            const allocated: [*]u32 = @ptrCast(region);
            @memset(allocated[0 .. self.obj_size / 4], 0xCAFEBABE);

            return @ptrCast(region);
        }
        return null;
    }

    pub fn free(self: *Slab, ptr: [*]u8) bool {
        log.info("freeing ptr: {x}", .{ptr});
        const region: *FreeRegion = @ptrCast(@alignCast(ptr));
        // Clear the allocated memory before reusing it

        region.next = self.free_list;
        region.magic = 0xDEADBEEF;
        self.free_list = region;
        self.inuse -= 1;
        return true;
    }

    pub fn isEmpty(self: *const Slab) bool {
        return self.inuse == 0;
    }

    pub fn isFull(self: *const Slab) bool {
        return self.free_list == null;
    }
};

pub fn SlabCacheTyped(comptime T: type) type {
    return struct {
        base: *SlabCache,

        pub fn fromBase(base: *SlabCache) @This() {
            return .{ .base = base };
        }

        pub fn next(self: *const @This()) ?*SlabCache {
            return self.base.next;
        }

        pub fn alloc(self: *const @This()) !*T {
            return @ptrCast(@alignCast(try self.base.allocate()));
        }

        pub fn free(self: *const @This(), ptr: *T) void {
            self.base.free(@ptrCast(ptr));
        }

        pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            self.base.deinit(allocator);
        }
    };
}

/// A slab cache manages multiple slabs of the same object size
pub const SlabCache = extern struct {
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
            .next = null,
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
        const slab_size = @max(
            self.min_objects * self.obj_size,
            utils.PAGE_SIZE,
        );

        // Calculate the best order for allocation
        const pages_needed = std.math.divCeil(usize, slab_size, utils.PAGE_SIZE) catch unreachable;

        // Allocate memory using the buddy allocator
        const memory_addr = try pmm.allocatePageBlock(pages_needed, .@"1") + globals.hhdm_offset;
        const memory = @as([*]u8, @ptrFromInt(memory_addr))[0..slab_size];

        const new_slab = try Slab.init(memory, self.obj_size);

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
        var prev: ?*Slab = null;

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
        prev = null;

        while (current) |slab| {
            if (slab.free(@ptrCast(ptr))) {
                // Move to partial list
                if (prev) |p| {
                    p.next = slab.next;
                } else {
                    self.full_slabs = slab.next;
                }
                slab.next = self.partial_slabs;
                self.partial_slabs = slab;
                self.total_allocated -= 1;
                return true;
            }
            prev = slab;
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
                pmm.freePageBlock(@intFromPtr(slab.memory.ptr) - globals.hhdm_offset, pages) catch {};
                allocator.destroy(slab);
                current = next;
            }
        }

        self.* = undefined;
    }
};
