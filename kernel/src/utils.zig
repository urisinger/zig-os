const std = @import("std");
const log = std.log.scoped(.utils);
const builtin = @import("builtin");
const cpu = @import("cpu.zig");

// 4kb
pub const PAGE_SIZE = KB(4);

// 2mb
pub const LARGE_PAGE_SIZE = MB(2);

pub const BYTES_PER_KB = 1024;
pub const BYTES_PER_MB = 1024 * 1024;
pub const BYTES_PER_GB = 1024 * 1024 * 1024;

pub fn KB(kb: u64) u64 {
    return kb * BYTES_PER_KB;
}

pub fn MB(mb: u64) u64 {
    return mb * BYTES_PER_MB;
}

pub fn GB(gb: u64) u64 {
    return gb * BYTES_PER_GB;
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);
    log.err("KERNEL PANIC: {s}\n", .{msg});

    if (error_return_trace) |trace| {
        log.err("stacktrace: {}", .{trace.*});
    }
    cpu.halt();
}
