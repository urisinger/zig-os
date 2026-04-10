const std = @import("std");
const log = std.log.scoped(.serial);
const PORT = 0x3f8;

const root = @import("root");
const arch = root.arch;
const instr = arch.instr;

pub fn writer() std.io.Writer(void, error{}, write) {
    return .{ .context = {} };
}

fn write(_: void, str: []const u8) error{}!usize {
    puts(str);
    return str.len;
}

const SerialError = error{
    SerialFaulty,
};

pub fn init() SerialError!void {
    instr.outb(PORT + 1, 0x00); // Disable all interrupts
    instr.outb(PORT + 3, 0x80); // Enable DLAB (set baud rate divisor)
    instr.outb(PORT + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
    instr.outb(PORT + 1, 0x00); //                  (hi byte)
    instr.outb(PORT + 3, 0x03); // 8 bits, no parity, one stop bit
    instr.outb(PORT + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    instr.outb(PORT + 4, 0x0B); // IRQs enabled, RTS/DSR set
    instr.outb(PORT + 4, 0x1E); // Set in loopback mode, test the serial chip
    instr.outb(PORT + 0, 0xAE); // Test serial chip (send byte 0xAE and check if serial returns same byte)

    // Check if serial is faulty (i.e: not same byte as sent)
    if (instr.inb(PORT + 0) != 0xAE) {
        return SerialError.SerialFaulty; // Return a Zig error if the test fails
    }

    // If serial is not faulty, set it in normal operation mode
    // (not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled)
    instr.outb(PORT + 4, 0x0F);
    instr.outb(PORT + 1, 0x01); // Enable Receiver Data Available Interrupt

    return; // Success, no error
}

pub fn initInterrupts() void {
    arch.registerInterrupt(0x24, irq, .int, .user);
    arch.setRedirEntry(0x4, .{
        .vector = 0x24,
        .delivery_mode = .Fixed,
        .destination_mode = .Physical,
        .pin_polarity = 0,
        .remote_IRR = 0,
        .trigger_mode = 1,
        .mask = 0,
        .destination = arch.getContext().apic_id,
    });
}

fn isTransmitEmpty() bool {
    return instr.inb(PORT + 5) & 0x20 != 0;
}

pub fn hasData() bool {
    return instr.inb(PORT + 5) & 1 != 0;
}

pub fn readByte() u8 {
    while (!hasData()) {}
    return instr.inb(PORT);
}

pub fn irq(ctx: *arch.context.Context) *arch.context.Context {
    while (hasData()) {
        const byte = instr.inb(PORT);
        if (byte == 'q') {
            log.info("Serial 'q' received, shutting down...", .{});
            arch.shutdownSuccess();
        }
    }
    arch.lapic.sendEoi();
    return ctx;
}

pub fn writeByte(a: u8) void {
    while (!isTransmitEmpty()) {}

    instr.outb(PORT, a);
}

pub fn puts(str: []const u8) void {
    for (str) |byte| {
        writeByte(byte);
    }
}
