const std = @import("std");
const log = std.log;

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
    .log_level = .info,
};

export fn _start() callconv(.C) noreturn {
    logger.init();
    boot.init() catch @panic("failed to init boot params");

    memory.init();

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    const allocator = gpa.allocator();

    const arr = allocator.alloc(u8, 100) catch unreachable;

    arr[10] = 3;
    allocator.free(arr);
    log.info("finished with {}", .{gpa.deinit()});
    done();
}
