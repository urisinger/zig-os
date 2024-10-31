const std = @import("std");
const PORT = 0x3f8;

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
    outb(PORT + 1, 0x00); // Disable all interrupts
    outb(PORT + 3, 0x80); // Enable DLAB (set baud rate divisor)
    outb(PORT + 0, 0x03); // Set divisor to 3 (lo byte) 38400 baud
    outb(PORT + 1, 0x00); //                  (hi byte)
    outb(PORT + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(PORT + 2, 0xC7); // Enable FIFO, clear them, with 14-byte threshold
    outb(PORT + 4, 0x0B); // IRQs enabled, RTS/DSR set
    outb(PORT + 4, 0x1E); // Set in loopback mode, test the serial chip
    outb(PORT + 0, 0xAE); // Test serial chip (send byte 0xAE and check if serial returns same byte)

    // Check if serial is faulty (i.e: not same byte as sent)
    if (inb(PORT + 0) != 0xAE) {
        return SerialError.SerialFaulty; // Return a Zig error if the test fails
    }

    // If serial is not faulty, set it in normal operation mode
    // (not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled)
    outb(PORT + 4, 0x0F);

    return; // Success, no error
}

fn is_transmit_empty() bool {
    return inb(PORT + 5) & 0x20 != 0;
}

pub fn write_byte(a: u8) void {
    while (!is_transmit_empty()) {}

    outb(PORT, a);
}

pub fn puts(str: []const u8) void {
    for (str) |byte| {
        write_byte(byte);
    }
}

inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [port] "{dx}" (port),
          [value] "{al}" (value),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}
