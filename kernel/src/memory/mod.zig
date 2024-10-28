const std = @import("std");
const log = std.log;
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");
const utils = @import("../utils.zig");
const globals = @import("../globals.zig");
const VirtualAddress = paging.VirtualAddress;

const align_up = std.mem.alignForward;
const align_down = std.mem.alignBackward;

const Allocator = std.mem.Allocator;

var heap_start: u64 = 0;
var heap_end: u64 = 0;

pub fn init() void {
    pmm.init() catch @panic("failed to init");

    paging.init() catch |err| {
        log.err("paging.init error: {}", .{err});
        @panic("failed to init paging {}");
    };
    heap_start = utils.div_up(@intFromPtr(&globals.kernel_end), utils.PAGE_SIZE) * utils.PAGE_SIZE;
    heap_end = heap_start;
}

pub const page_allocator: Allocator = Allocator{
    .ptr = undefined,
    .vtable = &Allocator.VTable{
        .alloc = alloc,
        .free = free,
        .resize = resize,
    },
};

pub fn alloc(_: *anyopaque, len: usize, ptr_align: u8, _: usize) ?[*]u8 {
    heap_end = align_up(u64, heap_end, @as(u64, 1) << @intCast(ptr_align));

    const num_pages = (len + utils.PAGE_SIZE - 1) / utils.PAGE_SIZE;
    const alloc_start = heap_end;

    for (0..num_pages) |_| {
        const phys_page = pmm.allocate_page() catch {
            log.err("Could not allocate physical page", .{});
            return null;
        };

        paging.map_page(@bitCast(heap_end), phys_page, .{ .present = true, .read_write = .read_write }) catch {
            log.err("could not map virtual page", .{});
            return null;
        };

        heap_end += utils.PAGE_SIZE;
    }

    return @ptrFromInt(alloc_start);
}

pub fn free(_: *anyopaque, buf: []u8, _: u8, _: usize) void {
    log.info("called free", .{});
    const start_addr = @intFromPtr(buf.ptr);
    const num_pages = (buf.len + utils.PAGE_SIZE - 1) / utils.PAGE_SIZE;

    for (0..num_pages) |page_index| {
        const page_vaddr = start_addr + page_index * utils.PAGE_SIZE;

        const phys_page = paging.get_paddr(@bitCast(page_vaddr)) catch unreachable;

        pmm.free_page(phys_page) catch unreachable;

        log.info("freed page: {}", .{page_index});
    }
}

pub fn resize(_: *anyopaque, _: []u8, _: u8, _: usize, _: usize) bool {
    return false;
}
