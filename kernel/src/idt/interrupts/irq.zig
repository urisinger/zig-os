const std = @import("std");
const idt = @import("../idt.zig");
const apic = @import("../../apic/mod.zig");

const ps2 = @import("../../drivers/ps2.zig");

const keyboard = @import("../../drivers/keyboard/ps2.zig");

pub fn syscall(_: *volatile idt.Context) void {
    std.log.info("hi", .{});
}

var keyboard_state = keyboard.DriverState{};

pub fn irq1(_: *volatile idt.Context) void {
    const scancode = ps2.readData() catch {apic.sendEoi(); std.log.info("hh", .{}); return;};
    if (keyboard_state.handleScancode(scancode)) |key| {
        std.log.info("Key event: {}", .{key});
    }
    apic.sendEoi();
}
