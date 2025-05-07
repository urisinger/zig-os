const std = @import("std");
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

    // Now that the keyboard is initialized and ready, enable IRQ1
    try ps2.enableInterrupt(1);
}

pub const DriverState = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,


    pub fn handleScancode(self: *DriverState, scancode: u8) ?KeyCode {
        const released = (scancode & 0x80) != 0;
        const code = scancode & 0x7F;

        return switch (code) {
            0x2A, 0x36 => blk: {
                self.shift = !released;
                break :blk null;
            },
            0x1C => if (!released) .Enter else null,
            0x0E => if (!released) .Backspace else null,
            0x10 => if (!released) .Q else null,
            0x11 => if (!released) .W else null,
            0x12 => if (!released) .E else null,
            0x13 => if (!released) .R else null,
            // ... more keys
            else => null,
        };
    }
};
