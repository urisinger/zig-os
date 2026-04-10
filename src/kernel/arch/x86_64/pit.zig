const std = @import("std");
const root = @import("root");
const instr = root.arch.instr;

const PORT_CHAN0 = 0x40;
const PORT_COMMAND = 0x43;
pub const FREQUENCY = 1193182;

pub const Channel = enum(u2) {
    Channel0 = 0,
    Channel1 = 1,
    Channel2 = 2,
    ReadBack = 3,
};

pub const AccessMode = enum(u2) {
    LatchCount = 0,
    LowByteOnly = 1,
    HighByteOnly = 2,
    LowHighByte = 3,
};

pub const OperatingMode = enum(u3) {
    InterruptOnTerminalCount = 0,
    HardwareRetriggerableOneShot = 1,
    RateGenerator = 2,
    SquareWaveGenerator = 3,
    SoftwareTriggeredStrobe = 4,
    HardwareTriggeredStrobe = 5,
};

const Command = packed struct(u8) {
    binary_mode: u1,
    operating_mode: OperatingMode,
    access_mode: AccessMode,
    channel: Channel,
};

pub fn prepareSleep(ticks: u16) void {
    const cmd = Command{
        .channel = .Channel0,
        .access_mode = .LowHighByte,
        .operating_mode = .InterruptOnTerminalCount,
        .binary_mode = 0,
    };

    instr.outb(PORT_COMMAND, @bitCast(cmd));
    instr.outb(PORT_CHAN0, @intCast(ticks & 0xFF));
    instr.outb(PORT_CHAN0, @intCast((ticks >> 8) & 0xFF));
}

pub fn readCounter() u16 {
    const latch = Command{
        .channel = .Channel0,
        .access_mode = .LatchCount,
        .operating_mode = .InterruptOnTerminalCount,
        .binary_mode = 0,
    };

    instr.outb(PORT_COMMAND, @bitCast(latch));
    const low = instr.inb(PORT_CHAN0);
    const high = instr.inb(PORT_CHAN0);
    return (@as(u16, high) << 8) | low;
}

pub fn sleepMs(ms: u32) void {
    const total_ticks = (FREQUENCY / 1000) * ms;
    const ticks: u16 = @intCast(@min(total_ticks, 0xFFFF));

    prepareSleep(ticks);

    while (true) {
        const current = readCounter();
        if (current == 0 or current > ticks) break;
    }
}
