const vmm = @import("vmm.zig");
const pmm = @import("../pmm.zig");
const paging = @import("../page_table.zig");
const utils = @import("../../utils.zig");
const globals = @import("../../globals.zig");

const std= @import("std");

const Error = error{
    OutOfBounds,
};

pub fn allocateUserExecutablePageWithCode(
    vm: *vmm.VmAllocator,
    page_table: *paging.PageMapping,
    code: []const u8,
) !usize {
    const page_size = utils.PAGE_SIZE;

    const virt = vm.alloc(page_size, page_size) orelse return Error.OutOfBounds;

    const phys = try pmm.allocatePage();

    const temp_flags = .{
        .present = true,
        .read_write = .read_write,
        .user_supervisor = .supervisor,
    };

    try page_table.mapPage(@bitCast(virt), phys, temp_flags);

    const virt_ptr: [*]u8 = @ptrFromInt(virt);
    @memcpy(virt_ptr[0..code.len], code);

    try page_table.setPageFlags(@bitCast(virt), .{
        .present = true,
        .read_write = .read_execute,
        .user_supervisor = .user,
    });

    return virt;
}


pub fn allocateUserPages(
    vm: *vmm.VmAllocator,      // Virtual memory allocator for user space
    page_table: *paging.PageMapping,   // User-level page table
    num_pages: usize            // How many pages to allocate
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
