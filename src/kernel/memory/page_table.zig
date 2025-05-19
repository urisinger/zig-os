const std = @import("std");
const log = std.log.scoped(.page_table);

const utils = @import("../utils.zig");

const pmm = @import("pmm.zig");

const globals = @import("../globals.zig");
const boot = @import("../boot.zig");

const cpu = @import("../cpu.zig");

const framebuffer = @import("../display/framebuffer.zig");

pub const Error = error{
    EntryNotPresent,

    // Allocator errors
    OutOfMemory,
    InvalidSize,
    InvalidAddress,
    NotInitialized,
};

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

pub const PageMapping = extern struct {
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

            try pml4.mapPage(current_vaddr, current_paddr, flags);
        }
    }

    pub fn mmapLarge(
        pml4: *PageMapping,
        vaddr: VirtualAddress,
        paddr: u64,
        num_pages: u64,
        flags: MmapFlags,
    ) Error!void {
        for (0..num_pages) |page_index| {
            const current_vaddr: VirtualAddress = @bitCast(@as(u64, @bitCast(vaddr)) + @as(u64, page_index) * utils.LARGE_PAGE_SIZE);

            const current_paddr = @as(u64, @bitCast(paddr)) + @as(u64, page_index) * utils.LARGE_PAGE_SIZE;

            try pml4.mapPageLarge(current_vaddr, current_paddr, flags);
        }
    }

    pub fn mapPage(
        pml4: *PageMapping,
        vaddr: VirtualAddress,
        paddr: u64,
        flags: MmapFlags,
    ) Error!void {
        const pdp = try pml4.getOrCreate(vaddr.pml4_idx);
        const pd = try pdp.getOrCreate(vaddr.pdp_idx);
        const pt = try pd.getOrCreate(vaddr.pd_idx);

        const entry = &pt.mappings[vaddr.pt_idx];

        entry.* = @bitCast(paddr);
        entry.* = entry.set_flags(flags);
        entry.present = true;
    }

    pub fn mapPageLarge(
        pml4: *PageMapping,
        vaddr: VirtualAddress,
        paddr: u64,
        flags: MmapFlags,
    ) Error!void {
        const pdp = try pml4.getOrCreate(vaddr.pml4_idx);
        const pd = try pdp.getOrCreate(vaddr.pdp_idx);

        const entry = &pd.mappings[vaddr.pd_idx];

        entry.* = @bitCast(paddr);
        entry.* = entry.set_flags(flags);
        entry.present = true;
        entry.page_size = .large;
    }

    fn getOrCreate(
        self: *PageMapping,
        index: u9,
    ) Error!*PageMapping {
        const entry = &self.mappings[index];
        if (!entry.present) {
            const page = try pmm.allocatePage();
            const page_ptr: [*]u32 = @ptrFromInt(page + globals.hhdm_offset);
            @memset(page_ptr[0..1024], 0);

            entry.* = @bitCast(page);
            entry.present = true;
            entry.user_supervisor = .user;
            entry.read_write = .read_write;
        }
        return @ptrFromInt(entry.get_addr() + globals.hhdm_offset);
    }

    pub fn unmapPage(pml4: *PageMapping, vaddr: VirtualAddress) Error!void {
        const pdp = try pml4.getEntry(vaddr.pml4_idx);
        const pd = try pdp.getEntry(vaddr.pdp_idx);
        const pt = try pd.getEntry(vaddr.pd_idx);
        const entry = &pt.mappings[vaddr.pt_idx];

        entry.present = false;
    }

    pub fn setPageFlags(pml4: *PageMapping, vaddr: VirtualAddress, flags: MmapFlags) Error!void {
        const pdp = try pml4.getEntry(vaddr.pml4_idx);
        const pd = try pdp.getEntry(vaddr.pdp_idx);
        const pt = try pd.getEntry(vaddr.pd_idx);
        const entry = &pt.mappings[vaddr.pt_idx];

        entry.* = entry.set_flags(flags);
    }

    pub fn getPaddr(pml4: *const PageMapping, vaddr: VirtualAddress) Error!u64 {
        const pdp = try pml4.getEntry(vaddr.pml4_idx);

        const pd = try pdp.getEntry(vaddr.pdp_idx);
        if (pd.mappings[vaddr.pd_idx].page_size == .large) {
            return (@as(u64, pd.mappings[vaddr.pd_idx].addr) << 21) + @as(u64, @bitCast((@as(u64, @bitCast(vaddr)) & ((1 << 21) - 1))));
        }
        const pt = try pd.getEntry(vaddr.pd_idx);
        const entry = pt.mappings[vaddr.pt_idx];

        if (!entry.present) {
            return Error.EntryNotPresent;
        }

        return entry.get_addr() + vaddr.offset;
    }

    fn getEntry(self: *const PageMapping, index: u9) Error!*PageMapping {
        const entry = &self.mappings[index];
        if (!entry.present) {
            return Error.EntryNotPresent;
        }

        return @ptrFromInt(entry.get_addr() + globals.hhdm_offset);
    }
};
