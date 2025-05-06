const std = @import("std");
const log = std.log;

const cpu = @import("../cpu.zig");
const outb = cpu.outb;
const inb = cpu.inb;

const PS2_COMMAND = 0x64;
const PS2_DATA = 0x60;

var dual_channel = true;

const COMMAND_TIMER_LIMIT = 1000;

pub const Error = error{
    CommandTimeout,
    InvalidPort,
    ControllerMalfunction,
    DeviceResetFailed,
    NoDeviceResponse,
};

fn waitForInputBufferEmpty() Error!void {
    var command_timer: u32 = 0;
    while (inb(PS2_COMMAND) & 0b10 != 0) {
        command_timer += 1;
        if (command_timer > COMMAND_TIMER_LIMIT) {
            return Error.CommandTimeout;
        }
    }
}

fn waitForOutputBufferFull() Error!void {
    var command_timer: u32 = 0;
    while (inb(PS2_COMMAND) & 0b1 == 0) {
        command_timer += 1;
        if (command_timer > COMMAND_TIMER_LIMIT) {
            return Error.CommandTimeout;
        }
    }
}

fn sendCommand(cmd: u8) Error!void {
    outb(PS2_COMMAND, cmd);
}

pub fn sendData(data: u8) Error!void {
    try waitForInputBufferEmpty();
    outb(PS2_DATA, data);
}

pub fn readData() Error!u8 {
    try waitForOutputBufferFull();
    return inb(PS2_DATA);
}


fn enableDevice(port: u8) Error!void {
    switch (port) {
        1 => try sendCommand(0xAE), // Enable first PS/2 port
        2 => try sendCommand(0xA8), // Enable second PS/2 port
        else => return Error.InvalidPort, // Invalid port
    }
}

fn resetDevice(port: u8) Error!void {
    // Send the reset command (0xFF) to the specified port
    if (port == 1) {
        try sendData(0xFF);
    } else if (port == 2) {
        try sendCommand(0xD4); // Specify second PS/2 port
        try sendData(0xFF);
    } else {
        return Error.InvalidPort;
    }

    // Wait for the response from the device
    const ack = try readData();
    if (ack != 0xFA) {
        return Error.DeviceResetFailed;
    }

    // Check for device self-test completion
    const result = try readData();
    if (result != 0xAA) {
        return Error.DeviceResetFailed;
    }

    log.info("PS/2 device reset successful on port {d}", .{port});
}

pub fn enableAndResetDevices() Error!void {
    // Enable and reset first PS/2 port
    try enableDevice(1);
    try resetDevice(1);

    if (dual_channel) {
        // Enable and reset second PS/2 port
        try enableDevice(2);
        try resetDevice(2);
    } else {
        log.info("Second PS/2 port not available", .{});
    }
}

pub fn writeDataToPort(port: u8, data: u8) Error!void {
    switch (port) {
        1 => {
            try sendData(data);
        },
        2 => {
            try sendCommand(0xD4);
            try sendData(data);
        },
        else => return Error.InvalidPort,
    }
}


pub fn enableInterrupt(port: u8) !void {
    try sendCommand(0x20); // read config byte
    var config = try readData();
    if (port == 1) {
        config |= 1 << 0;
    } else if (port == 2) {
        config |= 1 << 1;
    } else {
        return Error.InvalidPort;
    }
    try sendCommand(0x60); // write config byte
    try sendData(config);
}

pub fn init() Error!void {
    // Disable both PS/2 ports
    try sendCommand(0xAD); // Disable first PS/2 port
    try sendCommand(0xA7); // Disable second PS/2 port

    _ = inb(PS2_DATA); // Flush output buffer

    // Read and modify configuration byte
    try sendCommand(0x20);
    var config = try readData();
    config &= ~(@as(u8, 1) << 6); // Disable translation
    config &= ~(@as(u8, 1)); // Disable first port IRQ

    // Write modified configuration byte
    try sendCommand(0x60);
    try sendData(config);

    // Perform controller self-test
    try sendCommand(0xAA);
    if (try readData() != 0x55) {
        return Error.ControllerMalfunction;
    }

    // Check for dual channel support
    try sendCommand(0xA8); // Enable second port
    try sendCommand(0x20);
    config = try readData();
    if (config & (@as(u8, 1) << 5) != 0) {
        dual_channel = false;
    } else {
        try sendCommand(0xA7); // Disable second PS/2 port
        config &= ~(@as(u8, 1) << 1); // Disable second port IRQ
    }

    // Finalize configuration
    config &= ~(@as(u8, 1) << 6); // Disable translation
    config &= ~(@as(u8, 1)); // Disable first port IRQ
    try sendCommand(0x60);
    try sendData(config);

    // Test first PS/2 port
    try sendCommand(0xAB);
    if (try readData() != 0x00) {
        return Error.ControllerMalfunction;
    }

    try enableAndResetDevices();


    log.info("Initialized PS/2 driver", .{});
}
