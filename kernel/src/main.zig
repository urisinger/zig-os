const std = @import("std");
const log = std.log;

const Gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false });

const limine = @import("limine");

const logger = @import("logger.zig");

const utils = @import("utils.zig");
const done = utils.done;
pub const panic = utils.panic;

const boot = @import("boot.zig");

const pmm = @import("memory/pmm.zig");

const paging = @import("memory/paging.zig");
const memory = @import("memory/mod.zig");

pub const os = @import("os.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

export fn _start() callconv(.C) noreturn {
    logger.init();
    boot.init();

    memory.init();

    done();
}
