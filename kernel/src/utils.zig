const std = @import("std");
const log = std.log;
const builtin = @import("builtin");

pub const PAGE_SIZE = 4096;

pub inline fn done() noreturn {
    while (true) {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile ("hlt"),
            .aarch64 => asm volatile ("wfi"),
            .riscv64 => asm volatile ("wfi"),
            else => unreachable,
        }
    }
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);
    log.err("PANIC: {s}\n", .{msg});

    if (error_return_trace) |trace| {
        log.err("stacktrace: {}", .{trace.*});
    }
    done();
}
