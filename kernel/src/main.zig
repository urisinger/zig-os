const std = @import("std");
const log = std.log;

const Gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false });

const logger = @import("logger.zig");

const utils = @import("utils.zig");
pub const panic = utils.panic;

const boot = @import("boot.zig");

const kheap = @import("memory/kheap.zig");
const idt = @import("idt/idt.zig");

const apic = @import("apic/mod.zig");

const cpu = @import("cpu.zig");

pub const os = @import("os.zig");

const framebuffer = @import("display/framebuffer.zig");
const console = @import("display/console.zig");

const ps2 = @import("drivers/ps2.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

export fn _start() callconv(.C) noreturn {
    framebuffer.init();
    console.init();
    logger.init();
    boot.init();

    kheap.init();
    idt.init();

    apic.configureLocalApic();

    ps2.init() catch @panic("failed to initilize ps2");

    cpu.sti();
    cpu.halt();
}
