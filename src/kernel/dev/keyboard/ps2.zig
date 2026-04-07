const std = @import("std");
const root = @import("root");
const log = std.log.scoped(.ps2);
const arch = root.arch;
const ps2 = @import("../ps2.zig");
const KeyCode = @import("mod.zig").KeyCode;

pub const Error = error{
    CommandTimeout,
    InvalidPort,
    ControllerMalfunction,
    DeviceResetFailed,
    NoDeviceResponse,
    DeviceNotAcknowledging,
};

var driver_state = DriverState{};

pub fn init() !void {
    _ = ps2.readData() catch 0;
    // Set Scancode Set 1
    try ps2.writeDataToPort(1, 0xF0); // Command: Set scancode
    const data = try ps2.readData();
    if (data != 0xFA) return error.DeviceNotAcknowledging;

    try ps2.writeDataToPort(1, 0x01); // Set 1
    if (try ps2.readData() != 0xFA) return error.DeviceNotAcknowledging;

    arch.registerInterrupt(0x20, irq, .int, .user);
    arch.writeRedirEntry(0x1, .{
        .vector = 0x20,
        .delivery_mode = .Fixed,
        .destination_mode = .Physical,
        .pin_polarity = 0,
        .remote_IRR = 0, 
        .trigger_mode = 1,
        .mask = 0,
        .destination = arch.getContext().apic_id, // Destination APIC ID (this processor)
    });
    try ps2.enableInterrupt(1);
}

pub const DriverState = struct {
    pub fn handleScancode(_: *DriverState, scancode: u8) ?KeyCode {
        const released = (scancode & 0x80) != 0;
        const code = scancode & 0x7F;

        return switch (code) {
            0x01 => if (!released) .Escape else null,
            0x1C => if (!released) .Enter else null,
            0x0E => if (!released) .Backspace else null,
            0x10 => if (!released) .Q else null,
            0x11 => if (!released) .W else null,
            0x12 => if (!released) .E else null,
            0x13 => if (!released) .R else null,
            else => null,
        };
    }
};

var keyboard_state = DriverState{};

pub fn irq(ctx: *volatile arch.context.Context) void {
    _ = ctx;
    const scancode = ps2.readData() catch {
        arch.apic.sendEoi();
        return;
    };
    if (keyboard_state.handleScancode(scancode)) |key| {
        log.info("Key event: {}", .{key});
        if (key == .Escape){
            arch.shutdownSuccess();
        }
    }

    arch.apic.sendEoi();
}
