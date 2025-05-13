const page_table = @import("../page_table.zig");
pub const PageMapping = page_table.PageMapping;
pub const VirtualAddress = page_table.VirtualAddress;
pub const MmapFlags = page_table.MmapFlags;

const pmm = @import("../pmm.zig");
const globals = @import("../../globals.zig");
const utils = @import("../../utils.zig");
const boot = @import("../../boot.zig");
const cpu = @import("../../cpu.zig");

const std = @import("std");
const log = std.log;

pub const Error = error{
    PageAlreadyMapped,
    Pml4NotInitialized,
    EntryNotPresent,
    AddressNotInKernelSpace,

    // Allocator errors
    OutOfBounds,
    NoFreePages,
    InvalidOperation,
    AllocatorNotInitialized,
};

const KERNEL_VADDR_BASE: usize = 0xffff_8000_0000_0000;

pub var base_kernel_pml4: ?*PageMapping = null;

pub fn createNewAddressSpace() !*PageMapping {
    if (base_kernel_pml4 == null) {
        log.err("Cannot create new address space: kernel PML4 not initialized", .{});
        return Error.Pml4NotInitialized;
    }

    const new_pml4: *PageMapping = @ptrFromInt(try pmm.allocatePage() + globals.hhdm_offset);
    @memset(&new_pml4.mappings, @bitCast(@as(u64, 0)));

    for (256..512) |i| {
        new_pml4.mappings[i] = base_kernel_pml4.?.mappings[i];
    }

    return new_pml4;
}

pub fn init() Error!void {
    const pml4: *PageMapping = @ptrFromInt(try pmm.allocatePage() + globals.hhdm_offset);

    @memset(&pml4.mappings, @bitCast(@as(u64, 0)));

    // Allocate a separate empty page for each top-half entry
    for (256..512) |i| {
        const entry = &pml4.mappings[i];
        const page = try pmm.allocatePage();
        const page_ptr: [*]u32 = @ptrFromInt(page + globals.hhdm_offset);
        @memset(page_ptr[0..1024], 0);

        entry.* = @bitCast(page);
        entry.present = true;
        entry.user_supervisor = .supervisor;
        entry.read_write = .read_write;
    }

    var base_physical = boot.params.?.kernel_base_physical;

    const kernel_text_bytes = @as(u64, @intFromPtr(&globals.kernel_text_end)) - @as(u64, @intFromPtr(&globals.kernel_text_start));
    const kernel_text_pages = std.math.divCeil(u64, kernel_text_bytes, utils.PAGE_SIZE) catch unreachable;
    try pml4.mmap(@bitCast(@intFromPtr(&globals.kernel_text_start)), base_physical, kernel_text_pages, .{
        .present = true,
        .read_write = .read_execute,
    });

    base_physical += kernel_text_pages * utils.PAGE_SIZE;

    const kernel_rod_bytes = @as(u64, @intFromPtr(&globals.kernel_rod_end)) - @as(u64, @intFromPtr(&globals.kernel_rod_start));
    const kernel_rod_pages = std.math.divCeil(u64, kernel_rod_bytes, utils.PAGE_SIZE) catch unreachable;
    try pml4.mmap(@bitCast(@intFromPtr(&globals.kernel_rod_start)), base_physical, kernel_rod_pages, .{
        .present = true,
        .read_write = .read_execute,
    });

    base_physical += kernel_rod_pages * utils.PAGE_SIZE;

    const kernel_data_bytes = @as(u64, @intFromPtr(&globals.kernel_data_end)) - @as(u64, @intFromPtr(&globals.kernel_data_start));
    const kernel_data_pages = std.math.divCeil(u64, kernel_data_bytes, utils.PAGE_SIZE) catch unreachable;
    try pml4.mmap(@bitCast(@intFromPtr(&globals.kernel_data_start)), base_physical, kernel_data_pages, .{
        .present = true,
        .read_write = .read_write,
    });

    base_physical += kernel_data_pages * utils.PAGE_SIZE;

    try mapAllMemory(pml4);

    cpu.setCr3(@intFromPtr(pml4) - globals.hhdm_offset);

    base_kernel_pml4 = pml4;

    std.log.info("{x}", .{getPaddr(@bitCast(@intFromPtr(base_kernel_pml4))) catch unreachable});

    log.info("initialized paging", .{});
}

pub fn mapAllMemory(pml4: *PageMapping) !void {
    const mem_map = boot.params.?.memory_map;

    // Calculate total memory and map each region
    for (mem_map) |mem_entry| {
        const phys_start = mem_entry.base;
        const phys_end = mem_entry.base + mem_entry.length;

        const aligned_start = std.mem.alignBackward(u64, phys_start, utils.PAGE_SIZE);
        const aligned_end = std.mem.alignForward(u64, phys_end, utils.PAGE_SIZE);

        var addr = aligned_start;
        while (addr < aligned_end) {
            const remaining = aligned_end - addr;

            if (addr % utils.LARGE_PAGE_SIZE == 0 and remaining >= utils.LARGE_PAGE_SIZE) {
                try pml4.mmapLarge(@bitCast(globals.hhdm_offset + addr), addr, 1, .{
                    .present = true,
                    .read_write = .read_write,
                    .cache_disable = true,
                });
                addr += utils.LARGE_PAGE_SIZE;
            } else {
                try pml4.mmap(@bitCast(globals.hhdm_offset + addr), addr, 1, .{
                    .present = true,
                    .read_write = .read_write,
                    .cache_disable = true,
                });
                addr += utils.PAGE_SIZE;
            }
        }
    }
}

pub fn mmap(vaddr: VirtualAddress, paddr: u64, num_pages: u64, flags: MmapFlags) !void {
    if (base_kernel_pml4 == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    if (@as(u64, @bitCast(vaddr)) < KERNEL_VADDR_BASE) {
        log.err("attempted to map user address in kernel map: {x}", .{@intFromEnum(vaddr)});
        return Error.AddressNotInKernelSpace;
    }
    try base_kernel_pml4.?.mmap(vaddr, paddr, num_pages, flags);
}

pub fn mmapLarge(vaddr: VirtualAddress, paddr: u64, num_pages: u64, flags: MmapFlags) !void {
    if (base_kernel_pml4 == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    if (@as(u64, @bitCast(vaddr)) < KERNEL_VADDR_BASE) {
        log.err("attempted to map user address in kernel map: {x}", .{@as(u64, @bitCast(vaddr))});
        return Error.AddressNotInKernelSpace;
    }
    try base_kernel_pml4.?.mmapLarge(vaddr, paddr, num_pages, flags);
}

pub fn mapPage(vaddr: VirtualAddress, paddr: u64, flags: MmapFlags) !void {
    if (base_kernel_pml4 == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    if (@as(u64, @bitCast(vaddr)) < KERNEL_VADDR_BASE) {
        log.err("attempted to map user address in kernel map: 0x{x}", .{@as(u64, @bitCast(vaddr))});
        return Error.AddressNotInKernelSpace;
    }
    try base_kernel_pml4.?.mapPage(vaddr, paddr, flags);
}

pub fn mapPageLarge(vaddr: VirtualAddress, paddr: u64, flags: MmapFlags) !void {
    if (base_kernel_pml4 == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    if (@as(u64, @bitCast(vaddr)) < KERNEL_VADDR_BASE) {
        log.err("attempted to map user address in kernel map: 0x{x}", .{@as(u64, @bitCast(vaddr))});
        return Error.AddressNotInKernelSpace;
    }
    try base_kernel_pml4.?.mapPageLarge(vaddr, paddr, flags);
}

pub fn unmapPage(vaddr: VirtualAddress) !void {
    if (base_kernel_pml4 == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    if (@as(u64, @bitCast(vaddr)) < KERNEL_VADDR_BASE) {
        log.err("attempted to unmap user address in kernel map: 0x{x}", .{@as(u64, @bitCast(vaddr))});
        return Error.AddressNotInKernelSpace;
    }
    try base_kernel_pml4.?.unmapPage(vaddr);
}

pub fn getPaddr(vaddr: VirtualAddress) !u64 {
    if (base_kernel_pml4 == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    if (@as(u64, @bitCast(vaddr)) < KERNEL_VADDR_BASE) {
        log.err("attempted to get user address in kernel map: 0x{x}", .{@as(u64, @bitCast(vaddr))});
        return Error.AddressNotInKernelSpace;
    }
    return base_kernel_pml4.?.getPaddr(vaddr);
}
