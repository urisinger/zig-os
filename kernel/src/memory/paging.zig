const std = @import("std");
const log = std.log;

const utils = @import("../utils.zig");

const pmm = @import("pmm.zig");

const globals = @import("../globals.zig");
const boot = @import("../boot.zig");

const Error = error{
    PageAlreadyMapped,
    OutOfBounds,
    NoFreePages,
    InvalidOperation,
    AllocatorNotInitialized,
    Pml4NotInitialized,
    EntryNotPresent,
    DivisionByZero,
};

var pml4_virt: ?*PageMapping = null;

pub fn init() Error!void {
    const pml4: *PageMapping = @ptrFromInt(try pmm.allocate_page() + globals.hhdm_offset);

    @memset(&pml4.mappings, @bitCast(@as(u64, 0)));

    var base_physical = boot.params.?.kernel_base_physical;

    const kernel_text_bytes = @as(u64, @intFromPtr(&globals.kernel_text_end)) - @as(u64, @intFromPtr(&globals.kernel_text_start));
    const kernel_text_pages = try std.math.divCeil(u64, kernel_text_bytes, utils.PAGE_SIZE);
    try pml4.mmap(@bitCast(@intFromPtr(&globals.kernel_text_start)), base_physical, kernel_text_pages, .{
        .present = true,
        .read_write = .read_execute,
    });
    base_physical += kernel_text_pages * utils.PAGE_SIZE;

    const kernel_rod_bytes = @as(u64, @intFromPtr(&globals.kernel_rod_end)) - @as(u64, @intFromPtr(&globals.kernel_rod_start));
    const kernel_rod_pages = try std.math.divCeil(u64, kernel_rod_bytes, utils.PAGE_SIZE);
    try pml4.mmap(@bitCast(@intFromPtr(&globals.kernel_rod_start)), base_physical, kernel_rod_pages, .{
        .present = true,
        .read_write = .read_execute,
    });

    base_physical += kernel_rod_pages * utils.PAGE_SIZE;

    const kernel_data_bytes = @as(u64, @intFromPtr(&globals.kernel_data_end)) - @as(u64, @intFromPtr(&globals.kernel_data_start));
    const kernel_data_pages = try std.math.divCeil(u64, kernel_data_bytes, utils.PAGE_SIZE);
    try pml4.mmap(@bitCast(@intFromPtr(&globals.kernel_data_start)), base_physical, kernel_data_pages, .{
        .present = true,
        .read_write = .read_write,
    });

    base_physical += kernel_data_pages * utils.PAGE_SIZE;

    const hhdm_pages = try std.math.divCeil(u64, globals.mem_size, utils.LARGE_PAGE_SIZE);
    try pml4.mmap_large(@bitCast(globals.hhdm_offset), 0, hhdm_pages, .{
        .present = true,
        .read_write = .read_write,
    });

    try pml4.mmap(@bitCast(@as(u64, 0)), 0, @divExact(utils.MB(1), utils.PAGE_SIZE), .{
        .present = true,
        .read_write = .read_write,
    });
    set_cr3(@intFromPtr(pml4) - globals.hhdm_offset);

    pml4_virt = pml4;
    log.info("initialized paging", .{});
}

pub fn mmap(vaddr: VirtualAddress, paddr: u64, num_pages: u64, flags: MmapFlags) !void {
    if (pml4_virt == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    try pml4_virt.?.mmap(vaddr, paddr, num_pages, flags);
}

pub fn mmap_large(vaddr: VirtualAddress, paddr: u64, num_pages: u64, flags: MmapFlags) !void {
    if (pml4_virt == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    try pml4_virt.?.mmap_large(vaddr, paddr, num_pages, flags);
}

pub fn map_page(vaddr: VirtualAddress, paddr: u64, flags: MmapFlags) !void {
    if (pml4_virt == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    try pml4_virt.?.map_page(vaddr, paddr, flags);
}

pub fn map_page_large(vaddr: VirtualAddress, paddr: u64, flags: MmapFlags) !void {
    if (pml4_virt == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    try pml4_virt.?.map_page_large_internal(vaddr, paddr, flags);
}

pub fn get_paddr(vaddr: VirtualAddress) !u64 {
    if (pml4_virt == null) {
        log.err("PML4 is not initialized", .{});
        return Error.Pml4NotInitialized;
    }
    return pml4_virt.?.get_paddr(vaddr);
}

inline fn get_cr3() u64 {
    return asm volatile ("mov %cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

inline fn set_cr3(pml4: u64) void {
    asm volatile ("mov %[pml], %cr3"
        :
        : [pml] "r" (pml4),
        : "memory"
    );
}

pub const ReadWrite = enum(u1) {
    read_execute = 0,
    read_write = 1,
};

pub const UserSupervisor = enum(u1) {
    supervisor = 0,
    user = 1,
};
pub const PageSize = enum(u1) {
    normal = 0,
    large = 1,
};

pub const MmapFlags = packed struct(u64) {
    present: bool = false,
    read_write: ReadWrite = .read_write,
    user_supervisor: UserSupervisor = .supervisor,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    page_size: PageSize = .normal,
    global: bool = false,
    _pad0: u3 = 0,
    addr: u36 = 0,
    _pad1: u15 = 0,
    execution_disable: bool = false,
};

pub const VirtualAddress = packed struct(u64) {
    offset: u12 = 0,
    pt_idx: u9 = 0,
    pd_idx: u9 = 0,
    pdp_idx: u9 = 0,
    pml4_idx: u9 = 0,
    _pad: u16 = 0,
};

const PageMapping = extern struct {
    const Entry = packed struct(u64) {
        present: bool = false,
        read_write: ReadWrite = .read_write,
        user_supervisor: UserSupervisor = .supervisor,
        write_through: bool = false,
        cache_disable: bool = false,
        accessed: bool = false,
        dirty: bool = false,
        page_size: PageSize = .normal,
        global: bool = false,
        _pad0: u3 = 0,
        addr: u36 = 0,
        _pad1: u15 = 0,
        execution_disable: bool = false,

        const Self = @This();
        pub fn set_flags(self: Self, flags: MmapFlags) Self {
            return @bitCast(@as(u64, @bitCast(self)) | @as(u64, @bitCast(flags)));
        }

        pub fn get_addr(self: *const Entry) u64 {
            return @as(u64, self.addr) << 12;
        }

        pub fn print(self: *const Entry) void {
            log.info("Addr: 0x{x} - 0x{x}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };

    mappings: [@divExact(utils.PAGE_SIZE, @sizeOf(Entry))]Entry,

    pub fn mmap(
        pml4: *PageMapping,
        vaddr: VirtualAddress,
        paddr: u64,
        num_pages: u64,
        flags: MmapFlags,
    ) Error!void {
        for (0..num_pages) |page_index| {
            const current_vaddr: VirtualAddress = @bitCast(@as(u64, @bitCast(vaddr)) + page_index * utils.PAGE_SIZE);
            const current_paddr = @as(u64, @bitCast(paddr)) + page_index * utils.PAGE_SIZE;

            try pml4.map_page(current_vaddr, current_paddr, flags);
        }
    }

    pub fn mmap_large(
        pml4: *PageMapping,
        vaddr: VirtualAddress,
        paddr: u64,
        num_pages: u64,
        flags: MmapFlags,
    ) Error!void {
        for (0..num_pages) |page_index| {
            const current_vaddr: VirtualAddress = @bitCast(@as(u64, @bitCast(vaddr)) + @as(u64, page_index) * utils.LARGE_PAGE_SIZE);
            const current_paddr = @as(u64, @bitCast(paddr)) + @as(u64, page_index) * utils.LARGE_PAGE_SIZE;

            try pml4.map_page_large(current_vaddr, current_paddr, flags);
        }
    }

    pub fn map_page(
        pml4: *PageMapping,
        vaddr: VirtualAddress,
        paddr: u64,
        flags: MmapFlags,
    ) Error!void {
        const pdp = try pml4.get_or_create(vaddr.pml4_idx);
        const pd = try pdp.get_or_create(vaddr.pdp_idx);
        const pt = try pd.get_or_create(vaddr.pd_idx);

        const entry = &pt.mappings[vaddr.pt_idx];
        if (entry.present) {
            return Error.PageAlreadyMapped;
        }

        entry.* = @bitCast(paddr);
        entry.* = entry.set_flags(flags);
        entry.present = true;
    }

    pub fn map_page_large(
        pml4: *PageMapping,
        vaddr: VirtualAddress,
        paddr: u64,
        flags: MmapFlags,
    ) Error!void {
        const pdp = try pml4.get_or_create(vaddr.pml4_idx);
        const pd = try pdp.get_or_create(vaddr.pdp_idx);

        const entry = &pd.mappings[vaddr.pd_idx];
        if (entry.present) {
            return Error.PageAlreadyMapped;
        }

        entry.* = @bitCast(paddr);
        entry.* = entry.set_flags(flags);
        entry.present = true;
        entry.page_size = .large;
    }

    fn get_or_create(
        self: *PageMapping,
        index: u9,
    ) Error!*PageMapping {
        const entry = &self.mappings[index];
        if (!entry.present) {
            const page = try pmm.allocate_page();
            const page_ptr: [*]u32 = @ptrFromInt(page + globals.hhdm_offset);
            @memset(page_ptr[0..1024], 0);

            entry.* = @bitCast(page);
            entry.present = true;
            entry.user_supervisor = .user;
            entry.read_write = .read_write;
        }

        return @ptrFromInt(entry.get_addr() + globals.hhdm_offset);
    }

    pub fn get_paddr(pml4: *const PageMapping, vaddr: VirtualAddress) Error!u64 {
        const hhdm_offset = globals.hhdm_offset;
        const pdp: *const PageMapping = @ptrFromInt(pml4.mappings[vaddr.pml4_idx].get_addr() + hhdm_offset);
        if (!pml4.mappings[vaddr.pml4_idx].present) {
            log.err("pml4 entery not present: {}", .{vaddr.pml4_idx});
            return Error.EntryNotPresent;
        }
        const pd: *const PageMapping = @ptrFromInt(pdp.mappings[vaddr.pdp_idx].get_addr() + hhdm_offset);
        if (!pdp.mappings[vaddr.pdp_idx].present) {
            log.err("pdp entery not present: {}", .{vaddr.pdp_idx});
            return Error.EntryNotPresent;
        }
        const pt: *const PageMapping = @ptrFromInt(pd.mappings[vaddr.pd_idx].get_addr() + hhdm_offset);
        if (!pd.mappings[vaddr.pd_idx].present) {
            log.err("pd entery not present: {}", .{vaddr.pd_idx});
            return Error.EntryNotPresent;
        }
        const entry = pt.mappings[vaddr.pt_idx];

        if (!entry.present) {
            log.err("pt entery not present: {}", .{vaddr.pt_idx});
            return Error.EntryNotPresent;
        }

        return entry.get_addr();
    }
};
