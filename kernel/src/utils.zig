const std = @import("std");
const log = std.log;
const builtin = @import("builtin");
const cpu = @import("cpu.zig");

// 4kb
pub const PAGE_SIZE = KB(4);

// 2mb
pub const LARGE_PAGE_SIZE = MB(2);

pub fn GB(mb: u64) u64 {
    return mb * 0x40000000;
}

pub fn MB(mb: u64) u64 {
    return mb * 0x100000;
}

pub fn KB(kb: u64) u64 {
    return kb * 0x400;
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);
    log.err("PANIC: {s}\n", .{msg});

    if (error_return_trace) |trace| {
        log.err("stacktrace: {}", .{trace.*});
    }
    cpu.halt();
}
