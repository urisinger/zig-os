const std = @import("std");
const PORT = 0x3f8;

const cpu = @import("cpu.zig");

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
    cpu.outb(PORT + 1, 0x00); // Disable all interrupts
    cpu.outb(PORT + 3, 0x80); // Enable DLAB (set baud rate divisor)
    cpu.outb(PORT + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
    cpu.outb(PORT + 1, 0x00); //                  (hi byte)
    cpu.outb(PORT + 3, 0x03); // 8 bits, no parity, one stop bit
    cpu.outb(PORT + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    cpu.outb(PORT + 4, 0x0B); // IRQs enabled, RTS/DSR set
    cpu.outb(PORT + 4, 0x1E); // Set in loopback mode, test the serial chip
    cpu.outb(PORT + 0, 0xAE); // Test serial chip (send byte 0xAE and check if serial returns same byte)

    // Check if serial is faulty (i.e: not same byte as sent)
    if (cpu.inb(PORT + 0) != 0xAE) {
        return SerialError.SerialFaulty; // Return a Zig error if the test fails
    }

    // If serial is not faulty, set it in normal operation mode
    // (not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled)
    cpu.outb(PORT + 4, 0x0F);

    return; // Success, no error
}

fn isTransmitEmpty() bool {
    return cpu.inb(PORT + 5) & 0x20 != 0;
}

pub fn writeByte(a: u8) void {
    while (!isTransmitEmpty()) {}

    cpu.outb(PORT, a);
}

pub fn puts(str: []const u8) void {
    for (str) |byte| {
        writeByte(byte);
    }
}
