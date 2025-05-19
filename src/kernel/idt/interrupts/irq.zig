const std = @import("std");
const log = std.log.scoped(.irq);
const idt = @import("../idt.zig");
const apic = @import("../../apic/mod.zig");

const ps2 = @import("../../drivers/ps2.zig");

const keyboard = @import("../../drivers/keyboard/ps2.zig");

var keyboard_state = keyboard.DriverState{};

pub fn irq1(_: *volatile idt.Context) void {
    const scancode = ps2.readData() catch {
        apic.sendEoi();
        return;
    };
    if (keyboard_state.handleScancode(scancode)) |key| {
        log.info("Key event: {}", .{key});
    }

    @panic("dont like nigga");
}
