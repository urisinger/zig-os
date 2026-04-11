const std = @import("std");
const log = std.log.scoped(.kheap);
const paging = @import("paging.zig");
const pmm = @import("../pmm.zig");

const root = @import("root");
const common = root.common;
const utils = common.utils;
const globals = common.globals;
pub const slab = @import("slab.zig");

pub const get_slab_cache = slab.get_slab_cache;

const SLAB_MAX_SIZE = 2048;

var generic_caches: [8]slab.SlabCache = undefined;
const generic_sizes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 2048 };

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &vtable,
};

pub const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .free = free,
    .resize = resize,
    .remap = remap,
};

pub fn init() void {
    pmm.init() catch @panic("failed to init pmm");
    paging.init() catch @panic("failed to init paging");

    for (generic_sizes, 0..) |size, i| {
        generic_caches[i] = slab.SlabCache.init(size, @max(4, slab.Slab.max_objects(utils.PAGE_SIZE, size)));
    }
}

fn getCacheIndex(len: usize) ?usize {
    if (len == 0 or len > SLAB_MAX_SIZE) return null;

    const size = std.math.ceilPowerOfTwo(usize, @max(len, 16)) catch return null;

    const msb = 63 - @clz(size);
    return msb - 4;
}

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (getCacheIndex(len)) |index| {
        const ptr = generic_caches[index].allocate() catch return null;
        return @ptrCast(ptr);
    }

    return allocPages(len, alignment);
}


fn free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    if (buf.len == 0) return;

    if (getCacheIndex(buf.len)) |index| {
        _ = generic_caches[index].free(buf.ptr);
        return;
    }

    freePages(buf);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    if (new_len == 0) {
        free(ctx, memory, alignment, ret_addr);
        return null;
    }

    const old_idx = getCacheIndex(memory.len);
    const new_idx = getCacheIndex(new_len);

    // If both are in the same slab bucket, no need to move memory
    if (old_idx != null and new_idx != null and old_idx.? == new_idx.?) {
        return memory.ptr;
    }

    const new_ptr = alloc(ctx, new_len, alignment, ret_addr) orelse return null;
    const to_copy = @min(memory.len, new_len);
    @memcpy(new_ptr[0..to_copy], memory[0..to_copy]);

    free(ctx, memory, alignment, ret_addr);
    return new_ptr;
}

pub fn resize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const old_idx = getCacheIndex(buf.len);
    const new_idx = getCacheIndex(new_len);

    if (old_idx != null) {
        const can_resize = new_idx != null and old_idx.? == new_idx.?;
        return can_resize;
    }

    const old_pages = std.math.divCeil(usize, buf.len, utils.PAGE_SIZE) catch unreachable;
    const new_pages = std.math.divCeil(usize, new_len, utils.PAGE_SIZE) catch unreachable;
    const can_resize_page = old_pages == new_pages;
    return can_resize_page;
}

fn allocPages(len: usize, alignment: std.mem.Alignment) ?[*]u8 {
    const num_pages = std.math.divCeil(usize, len, utils.PAGE_SIZE) catch unreachable;
    const addr = pmm.allocatePageBlock(num_pages, utils.getPageAlignment(alignment)) catch return null;
    const ptr: [*]u8 = @ptrFromInt(addr + globals.hhdm_offset);
    @memset(ptr[0 .. num_pages * utils.PAGE_SIZE], 0);
    return ptr;
}

fn freePages(buf: []u8) void {
    const addr = @intFromPtr(buf.ptr) - globals.hhdm_offset;
    const num_pages = std.math.divCeil(usize, buf.len, utils.PAGE_SIZE) catch unreachable;
    pmm.freePageBlock(addr, num_pages) catch {};
}
