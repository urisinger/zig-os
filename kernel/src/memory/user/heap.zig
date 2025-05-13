const vmm = @import("vmm.zig");
const pmm = @import("../pmm.zig");
const paging = @import("../page_table.zig");
const utils = @import("../../utils.zig");
const globals = @import("../../globals.zig");

const std = @import("std");

const Error = error{
    OutOfBounds,
};

pub fn allocateUserExecutablePageWithCode(
    vm: *vmm.VmAllocator,
    page_table: *paging.PageMapping,
    code: []const u8,
) !usize {
    const num_pages = std.math.divCeil(u64, code.len, utils.PAGE_SIZE) catch unreachable;

    const virt_base = vm.alloc(utils.PAGE_SIZE * num_pages, utils.PAGE_SIZE) orelse return Error.OutOfBounds;

    for (0..num_pages) |i| {
        const vaddr = virt_base + i * utils.PAGE_SIZE;
        const paddr = try pmm.allocatePage();

        const virt_ptr: [*]u8 = @ptrFromInt(paddr + globals.hhdm_offset);

        const start = i * utils.PAGE_SIZE;
        const end = @min(code.len, start + utils.PAGE_SIZE);
        const len = end - start;

        @memcpy(virt_ptr[0..len], code[start..end]);

        try page_table.mapPage(
            @bitCast(vaddr),
            paddr,
            .{
                .present = true,
                .read_write = .read_execute,
                .user_supervisor = .user,
            },
        );
    }

    return virt_base;
}

pub fn allocateUserPages(
    vm: *vmm.VmAllocator, // Virtual memory allocator for user space
    page_table: *paging.PageMapping, // User-level page table
    num_pages: usize, // How many pages to allocate
) !usize {
    const size_bytes = num_pages * utils.PAGE_SIZE;

    const virt_base = vm.alloc(size_bytes, utils.PAGE_SIZE) orelse return Error.OutOfBounds;

    for (0..num_pages) |i| {
        const vaddr = virt_base + i * utils.PAGE_SIZE;
        const paddr = try pmm.allocatePage();

        try page_table.mapPage(
            @bitCast(vaddr),
            paddr,
            .{
                .present = true,
                .read_write = .read_write,
                .user_supervisor = .user,
            },
        );
    }

    return virt_base;
}
