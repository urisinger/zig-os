const cpu = @import("cpu.zig");
const tss = @import("tss.zig");

pub var table = [_]GdtEntry{
    GdtEntry.empty(),

    GdtEntry.init(0, 0, GdtAccess.code(.Ring0), GdtFlags{ .long_mode = true, .granularity_4k = true }),
    GdtEntry.init(0, 0, GdtAccess.data(.Ring0), GdtFlags{ .long_mode = true, .granularity_4k = true }),

    GdtEntry.init(0, 0, GdtAccess.code(.Ring3), GdtFlags{ .long_mode = true, .granularity_4k = true }),
    GdtEntry.init(0, 0, GdtAccess.data(.Ring3), GdtFlags{ .long_mode = true, .granularity_4k = true }),

    // Tss
    GdtEntry.empty(),
    GdtEntry.empty(),
};

pub fn init() void {
    table[5] = GdtEntry.init(
        @truncate(@intFromPtr(&tss.tss)),
        @sizeOf(tss.Tss) - 1,
        @bitCast(@as(u8, 0x89)),
        @bitCast(@as(u4, 0)),
    );

    // TSS descriptor high part (manual encoding)
    table[6] = @bitCast(((@as(u64, @intFromPtr(&tss.tss)) >> 32) & 0xFFFFFFFF));

    const gdtr = GdtDescriptor{
        .size = @sizeOf(GdtEntry) * table.len,
        .offset = @intFromPtr(&table),
    };

    load(&gdtr); // your existing function that wraps `lgdt`

    // Inline assembly to flush segment registers
    asm volatile (
        \\  mov $0x10, %ax
        \\  mov %ax, %ds
        \\  mov %ax, %es
        \\  mov %ax, %fs
        \\  mov %ax, %gs
        \\  mov %ax, %ss
        \\  pushq $0x08
        \\  lea 1f(%rip), %rax
        \\  push %rax
        \\  lretq
        \\  1:
    );
}

pub const PrivilegeLevel = enum(u2) {
    Ring0 = 0,
    Ring1 = 1,
    Ring2 = 2,
    Ring3 = 3,
};

pub const GdtEntry = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: GdtAccess,
    limit_high: u4,
    flags: GdtFlags,
    base_high: u8,

    pub fn init(base: u32, limit: u32, access: GdtAccess, flags: GdtFlags) GdtEntry {
        return GdtEntry{
            .limit_low = @intCast(limit & 0xFFFF),
            .base_low = @intCast(base & 0xFFFF),
            .base_middle = @intCast((base >> 16) & 0xFF),
            .access = access,
            .limit_high = @intCast((limit >> 16) & 0xF),
            .flags = flags,
            .base_high = @intCast((base >> 24) & 0xFF),
        };
    }

    pub fn empty() GdtEntry {
        return @bitCast(@as(u64, 0));
    }
};

pub const GdtFlags = packed struct(u4) {
    avl: bool = false,
    long_mode: bool = false,
    default_size_32bit: bool = false,
    granularity_4k: bool = false,

    pub fn toBits(self: GdtFlags) u4 {
        return (@as(u4, @intFromBool(self.avl)) << 0) |
            (@as(u4, @intFromBool(self.long_mode)) << 1) |
            (@as(u4, @intFromBool(self.default_size_32bit)) << 2) |
            (@as(u4, @intFromBool(self.granularity_4k)) << 3);
    }
};

pub const GdtAccess = packed struct(u8) {
    accessed: bool = false,
    readable_or_writable: bool = true,
    direction_or_conforming: bool = false,
    executable: bool = true,
    descriptor_type: bool = true, // true = code/data, false = system
    dpl: PrivilegeLevel = .Ring0,
    present: bool = true,

    pub fn toByte(self: GdtAccess) u8 {
        return (@as(u8, @intFromBool(self.accessed)) << 0) |
            (@as(u8, @intFromBool(self.readable_or_writable)) << 1) |
            (@as(u8, @intFromBool(self.direction_or_conforming)) << 2) |
            (@as(u8, @intFromBool(self.executable)) << 3) |
            (@as(u8, @intFromBool(self.descriptor_type)) << 4) |
            (@as(u8, @intFromEnum(self.dpl)) << 5) |
            (@as(u8, @intFromBool(self.present)) << 7);
    }

    pub fn code(dpl: PrivilegeLevel) GdtAccess {
        return .{
            .executable = true,
            .readable_or_writable = true,
            .descriptor_type = true,
            .dpl = dpl,
            .present = true,
        };
    }

    pub fn data(dpl: PrivilegeLevel) GdtAccess {
        return .{
            .executable = false,
            .readable_or_writable = true,
            .descriptor_type = true,
            .dpl = dpl,
            .present = true,
        };
    }
};

pub const GdtDescriptor = packed struct {
    size: u16,
    offset: usize,
};

pub fn load(gdtr: *const GdtDescriptor) void {
    cpu.lgdt(@intFromPtr(gdtr));
}
