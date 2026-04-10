const std = @import("std");

pub const DeliveryMode = enum(u3) {
    Fixed = 0b000,
    LowPriority = 0b001,
    SMI = 0b010,
    NMI = 0b100,
    INIT = 0b101,
    ExtINT = 0b111,
};

pub const DestinationMode = enum(u1) {
    Physical = 0,
    Logical = 1,
};

pub const RedirectionEntry = packed struct(u64) {
    vector: u8,
    delivery_mode: DeliveryMode,
    destination_mode: DestinationMode,
    delivery_status: u1 = 0,
    pin_polarity: u1 = 0,
    remote_IRR: u1 = 0,
    trigger_mode: u1 = 0,
    mask: u1 = 0,
    reserved: u39 = 0,
    destination: u8,
};

var base_ptr: [*]volatile u32 = undefined;

pub fn init(vaddr: usize) void {
    base_ptr = @ptrFromInt(vaddr);
}

pub inline fn write(reg: u8, value: u32) void {
    base_ptr[0] = reg;
    base_ptr[4] = value;
}

pub inline fn read(reg: u8) u32 {
    base_ptr[0] = reg;
    return base_ptr[4];
}

pub fn setRedirEntry(irq: u8, entry: RedirectionEntry) void {
    const low_reg = 0x10 + (irq * 2);
    const high_reg = low_reg + 1;
    const raw = @as(u64, @bitCast(entry));

    write(low_reg, @truncate(raw));
    write(high_reg, @truncate(raw >> 32));
}

pub fn getRedirCount() u8 {
    return @intCast((read(0x01) >> 16) & 0xFF);
}
