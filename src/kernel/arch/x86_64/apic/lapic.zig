const std = @import("std");
const root = @import("root");
const instr = root.arch.instr;
const pit = @import("../pit.zig");

const REG_ID         = 0x02;
const REG_EOI        = 0x0B;
const REG_SVR        = 0x0F;
const REG_ICR_LOW    = 0x30;
const REG_ICR_HI     = 0x31;
const REG_LVT_TMR    = 0x32;
const REG_TMR_INIT   = 0x38;
const REG_TMR_CUR    = 0x39;
const REG_TMR_DIV    = 0x3E;

const IA32_APIC_BASE = 0x1B;
const APIC_ENABLE_BIT = 1 << 11;

pub const TimerMode = enum(u2) {
    OneShot = 0,
    Periodic = 1,
    TscDeadline = 2,
};

pub const Divider = enum(u4) {
    Div2   = 0,
    Div4   = 1,
    Div8   = 2,
    Div16  = 3,
    Div32  = 8,
    Div64  = 9,
    Div128 = 10,
    Div1   = 11,
};

const LvtTimerEntry = packed struct(u32) {
    vector: u8,
    _reserved1: u4 = 0,
    delivery_status: u1 = 0,
    _reserved2: u3 = 0,
    mask: u1,
    mode: TimerMode,
    _reserved3: u13 = 0,
};

var base_ptr: [*]volatile u32 = undefined;

pub fn init(vaddr: usize) void {
    base_ptr = @ptrFromInt(vaddr);

    var msr = instr.readMsr(IA32_APIC_BASE);
    msr |= APIC_ENABLE_BIT;
    instr.writeMsr(IA32_APIC_BASE, msr);

    write(REG_SVR, 0x100 | 0xFF);
}

pub inline fn write(reg: u32, value: u32) void {
    base_ptr[reg * 4] = value;
}

pub inline fn read(reg: u32) u32 {
    return base_ptr[reg * 4];
}

pub inline fn sendEoi() void {
    write(REG_EOI, 0);
}

pub fn getApicId() u8 {
    return @intCast(read(REG_ID) >> 24);
}


var ticks_per_ms: u32 = 0;

pub fn calibrate() void {
    write(REG_TMR_DIV, @intFromEnum(Divider.Div16));

    const start_count: u32 = 0xFFFFFFFF;
    write(REG_TMR_INIT, start_count);

    pit.sleepMs(10);


    write(REG_LVT_TMR, @bitCast(LvtTimerEntry{
        .vector = 0xFF,
        .mask = 1,
        .mode = .OneShot,
    }));

    const ticks_in_10ms = start_count - read(REG_TMR_CUR);
    ticks_per_ms = ticks_in_10ms / 10;

    // Reset timer to a stopped state
    write(REG_TMR_INIT, 0);
}

pub fn startTimer(vector: u8, interval_ms: u32, periodic: bool) void {
    // Set Divider
    write(REG_TMR_DIV, @intFromEnum(Divider.Div16));

    // Set the count
    write(REG_TMR_INIT, ticks_per_ms * interval_ms);

    // Unmask to start interrupts
    write(REG_LVT_TMR, @bitCast(LvtTimerEntry{
        .vector = vector,
        .mask = 0,
        .mode = if (periodic) .Periodic else .OneShot,
    }));
}
