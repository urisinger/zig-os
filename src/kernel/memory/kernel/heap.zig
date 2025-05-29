const std = @import("std");
const log = std.log.scoped(.kheap);
const paging = @import("paging.zig");
const pmm = @import("../pmm.zig");

const utils = @import("../../utils.zig");
const globals = @import("../../globals.zig");
const VirtualAddress = paging.VirtualAddress;

const cpu = @import("../../cpu.zig");

const Allocator = std.mem.Allocator;

const slab = @import("slab.zig");

pub const get_slab_cache = slab.get_slab_cache;

pub fn init() void {
    pmm.init() catch @panic("failed to init pmm");

    paging.init() catch |err| {
        log.err("paging.init error: {}", .{err});
        @panic("failed to init paging {}");
    };
}

pub const vtable = Allocator.VTable{
    .alloc = alloc,
    .free = free,
    .resize = resize,
    .remap = remap,
};

pub const page_allocator: Allocator = Allocator{
    .ptr = undefined,
    .vtable = &vtable,
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const num_pages = std.math.divCeil(usize, len, utils.PAGE_SIZE) catch unreachable;

    const page_aligment = utils.getPageAlignment(alignment);

    const start_addr = pmm.allocatePageBlock(num_pages, page_aligment) catch |err| {
        log.err("failed to allocate pages becuase of error: {}", .{err});
        return null;
    };

    const ptr: [*]u8 = @ptrFromInt(start_addr + globals.hhdm_offset);
    @memset(ptr[0 .. num_pages * utils.PAGE_SIZE], 0);

    return ptr;
}

fn free(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    const start_addr = @intFromPtr(buf.ptr) - globals.hhdm_offset;
    const num_pages = std.math.divCeil(usize, buf.len, utils.PAGE_SIZE) catch unreachable;
    pmm.freePageBlock(start_addr, num_pages) catch |err| {
        log.err("failed to free pages becuase of error: {}", .{err});
        return;
    };
}

fn remap(
    _: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    _: usize, // ret_addr (optional, unused here)
) ?[*]u8 {
    if (new_len == 0) return null;

    // Try allocating new memory
    const new_ptr = alloc(undefined, new_len, alignment, 0) orelse return null;

    // Copy over the old contents
    const to_copy = @min(memory.len, new_len);
    @memcpy(@as([*]u8, @ptrCast(new_ptr))[0..to_copy], memory[0..to_copy]);

    // Free old memory
    free(undefined, memory, alignment, 0);

    return new_ptr;
}

pub fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
    return false;
}
