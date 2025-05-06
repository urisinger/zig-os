const std = @import("std");
const idt = @import("../idt.zig");
const apic = @import("../../apic/mod.zig");

const ps2 = @import("../../drivers/ps2.zig");

pub fn irq0(_: *volatile idt.Context) void {
    std.log.info("hi", .{});
}

pub fn irq1(_: *volatile idt.Context) void{
    std.log.info("{}", .{ps2.readData() catch unreachable});
    apic.writeRegister(0xB, 0);
}
