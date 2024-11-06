const std = @import("std");
const log = std.log;

const cpu = @import("../cpu.zig");
const outb = cpu.outb;
const inb = cpu.inb;

const PS2_COMMAND = 0x64;
const PS2_DATA = 0x60;

pub const Error = error{
    CommandTimeout,
    ControllerMalfunction,
};

pub fn init() Error!void {
    outb(PS2_COMMAND, 0xAD); //Disable first PS/2 port
    outb(PS2_COMMAND, 0xA7); //Disable second PS/2 port
    _ = inb(PS2_DATA); //Flush output buffer
    outb(PS2_COMMAND, 0x20);
    while (inb(PS2_COMMAND) & 0b1 == 0) {}

    var config = inb(PS2_DATA);
    config &= ~(@as(u8, 1) << @intCast(6));
    config &= ~(1);
    while (inb(PS2_COMMAND) & 0b01 == 0) {}
    outb(PS2_DATA, config);

    outb(PS2_COMMAND, 0xAA);
    while (inb(PS2_COMMAND) & 0b01 == 0) {}
    if (inb(PS2_DATA) != 0x55) {
        return Error.ControllerMalfunction;
    }

    outb(PS2_COMMAND, 0xA8);
    config = inb(PS2_DATA);
    var dual_channel = true;
    if (config & (@as(u8, 1) << @intCast(5)) != 0) {
        dual_channel = false;
    }
    outb(PS2_COMMAND, 0xA7); //Disable second PS/2 port

    config &= ~(@as(u8, 1) << @intCast(6));
    config &= ~(@as(u8, 1) << @intCast(1));
    config &= ~(1);
    while (inb(PS2_COMMAND) & 0b01 == 0) {}
    outb(PS2_DATA, config);

    log.info("initlized ps2 driver", .{});
}
