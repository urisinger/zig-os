const std = @import("std");
const log = std.log.scoped(.kheap);
const paging = @import("paging.zig");
const pmm = @import("../pmm.zig");

const root = @import("root");
const common = root.common;
const utils = common.utils;
const globals = common.globals;
const slab = @import("slab.zig");

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
        generic_caches[i] = slab.SlabCache.init(
            size, 
            @max(4, slab.Slab.max_objects(utils.PAGE_SIZE, size))
        );
    }
}

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (len == 0) return null;

    if (len <= SLAB_MAX_SIZE) {
        inline for (generic_sizes, 0..) |size, i| {
            if (len <= size) {
                const ptr = generic_caches[i].allocate() catch return null;
                return @ptrCast(ptr);
            }
        }
    }

    return allocPages(len, alignment);
}

fn free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    if (buf.len == 0) return;

    if (buf.len <= SLAB_MAX_SIZE) {
        inline for (generic_sizes, 0..) |size, i| {
            if (buf.len <= size) {
                _ = generic_caches[i].free(buf.ptr);
                return;
            }
        }
    }

    freePages(buf);
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    if (new_len == 0) {
        free(ctx, memory, alignment, ret_addr);
        return null;
    }

    if (memory.len <= SLAB_MAX_SIZE) {
        inline for (generic_sizes) |size| {
            if (memory.len <= size and new_len <= size) return memory.ptr;
        }
    }

    const new_ptr = alloc(ctx, new_len, alignment, ret_addr) orelse return null;
    const to_copy = @min(memory.len, new_len);
    @memcpy(new_ptr[0..to_copy], memory[0..to_copy]);
    
    free(ctx, memory, alignment, ret_addr);
    return new_ptr;
}

pub fn resize(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    if (buf.len <= SLAB_MAX_SIZE) {
        inline for (generic_sizes) |size| {
            if (buf.len <= size) return new_len <= size;
        }
    }
    const old_pages = std.math.divCeil(usize, buf.len, utils.PAGE_SIZE) catch unreachable;
    const new_pages = std.math.divCeil(usize, new_len, utils.PAGE_SIZE) catch unreachable;
    return old_pages == new_pages;
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
