const vmm = @import("vmm.zig");
const pmm = @import("../pmm.zig");
const paging = @import("../page_table.zig");
const utils = @import("../../utils.zig");
const globals = @import("../../globals.zig");

const std = @import("std");

pub fn allocateUserPages(
    vma: *vmm.VmAllocator, // Virtual memory allocator for user space
    page_table: *paging.PageMapping, // User-level page table
    num_pages: usize, // How many pages to allocate
) !usize {
    const size_bytes = num_pages * utils.PAGE_SIZE;

    const virt_base = try vma.allocate(size_bytes, utils.PAGE_SIZE, .{ .permissions = .ReadWrite });

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
