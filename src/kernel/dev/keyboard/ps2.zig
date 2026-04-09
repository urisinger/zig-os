const std = @import("std");
const root = @import("root");
const log = std.log.scoped(.ps2_keyboard);
const arch = root.arch;
const ps2 = @import("../ps2.zig");
const keyboard = @import("mod.zig");

pub const Error = error{
    CommandTimeout,
    InvalidPort,
    ControllerMalfunction,
    DeviceResetFailed,
    NoDeviceResponse,
    DeviceNotAcknowledging,
};

pub fn init() !void {
    _ = ps2.readData() catch 0;
    // Set Scancode Set 1
    try ps2.writeDataToPort(1, 0xF0); // Command: Set scancode
    const data = try ps2.readData();
    if (data != 0xFA) return error.DeviceNotAcknowledging;

    try ps2.writeDataToPort(1, 0x01); // Set 1
    if (try ps2.readData() != 0xFA) return error.DeviceNotAcknowledging;

    arch.registerInterrupt(0x21, irq, .int, .user);
    arch.writeRedirEntry(0x1, .{
        .vector = 0x21,
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

pub fn handleScancode(scancode: u8) ?keyboard.KeyEvent {
    const released = (scancode & 0x80) != 0;
    const code = scancode & 0x7F;

    const state: keyboard.KeyState = if (released) .released else .pressed;

    const key_code: keyboard.KeyCode = switch (code) {
        0x01 => .Escape,
        0x10 => .Q, 0x11 => .W, 0x12 => .E, 0x13 => .R, 0x14 => .T, 0x15 => .Y, 0x16 => .U, 0x17 => .I, 0x18 => .O, 0x19 => .P,
        0x1E => .A, 0x1F => .S, 0x20 => .D, 0x21 => .F, 0x22 => .G, 0x23 => .H, 0x24 => .J, 0x25 => .K, 0x26 => .L,
        0x2C => .Z, 0x2D => .X, 0x2E => .C, 0x2F => .V, 0x30 => .B, 0x31 => .N, 0x32 => .M,
        0x1C => .Enter,
        0x0E => .Backspace,
        0x39 => .Space,
        0x0F => .Tab,
        0x2A => .LeftShift,
        0x36 => .RightShift,
        0x1D => .LeftControl,
        0x38 => .LeftAlt,
        else => .Unknown,
    };

    if (key_code == .Unknown) return null;
    return .{ .code = key_code, .state = state };
}

pub fn irq(ctx: *volatile arch.context.Context) void {
    _ = ctx;
    log.info("i am here", .{});
    const scancode = ps2.readData() catch {
        arch.apic.sendEoi();
        return;
    };

    log.info("i am here too", .{});
    if (handleScancode(scancode)) |event| {
        keyboard.Manager.handleEvent(event);
    }

    log.info("i am here three", .{});

    arch.apic.sendEoi();
}
