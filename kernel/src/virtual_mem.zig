const std = @import("std");
const log = std.log;

const utils = @import("utils.zig");

pub fn print_mmap() void {
    const page_mapping = get_mmap();
    var vaddr: VirtualAddress = .{};
    page_mapping.print(4, &vaddr);
}

pub fn get_mmap() *PageMapping {
    return @ptrFromInt(get_cr3());
}

pub inline fn get_cr3() u64 {
    return asm volatile ("mov %cr3, %[ret]"
        : [ret] "=r" (-> u64),
    );
}

const ReadWrite = enum(u1) {
    read_execute = 0,
    read_write = 1,
};
const UserSupervisor = enum(u1) {
    supervisor = 0,
    user = 1,
};
const PageSize = enum(u1) {
    normal = 0,
    large = 1,
};

const MmapFlags = packed struct(u64) {
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

const VirtualAddress = packed struct(u64) {
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

        pub fn getAddr(self: *const Entry) u64 {
            return u64(self.addr) << 12;
        }

        pub fn print(self: *const Entry) void {
            log.debug("entry: {*}", .{self});
            log.info("Addr: 0x{X} - 0x{X}", .{ self.getAddr(), @as(u64, @bitCast(self.*)) });
        }
    };

    mappings: [@divExact(utils.PAGE_SIZE, @sizeOf(Entry))]Entry,

    pub fn print(self: *const PageMapping, lvl: u8, vaddr: *VirtualAddress) void {
        for (&self.mappings, 0..) |*mapping, idx| {
            if (!mapping.present) continue;
            switch (lvl) {
                4 => vaddr.pml4_idx = @intCast(idx),
                3 => vaddr.pdp_idx = @intCast(idx),
                2 => vaddr.pd_idx = @intCast(idx),
                1 => {
                    vaddr.pt_idx = @intCast(idx);
                    log.info("VAddr: 0x{X}: {any}", .{ @as(u64, @bitCast(vaddr.*)), vaddr });
                    mapping.print();
                    continue;
                },
                else => unreachable,
            }
            log.debug("mapping: {*}", .{mapping});
            const next_level_mapping: *PageMapping = @ptrFromInt(mapping.getAddr());
            next_level_mapping.print(lvl - 1, vaddr);
        }
    }
};
