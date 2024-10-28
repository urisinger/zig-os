const builtin = @import("builtin");
const limine = @import("limine");
const std = @import("std");
const log = std.log;

const logger = @import("logger.zig");

const utils = @import("utils.zig");
const done = utils.done;
pub const panic = utils.panic;

const allocator = @import("allocator.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

pub export var base_revision: limine.BaseRevision = .{ .revision = 2 };

pub export var framebuffer_request: limine.FramebufferRequest = .{};

pub export var memory_map_request: limine.MemoryMapRequest = .{};

pub export var hhdm_request: limine.HhdmRequest = .{};

export fn _start() callconv(.C) noreturn {
    logger.init();
    if (!base_revision.is_supported()) {
        @panic("limine revision not supported");
    }

    var framebuffer: *limine.Framebuffer = undefined;
    if (framebuffer_request.response) |framebuffer_response| {
        if (framebuffer_response.framebuffer_count < 1) {
            @panic("no framebuffers in response");
        }

        framebuffer = framebuffer_response.framebuffers()[0];
        log.debug("Sucsesfully initialized framebuffer", .{});
    } else {
        @panic("No framebuffer response");
    }

    var bitmap_allocator =
        if (memory_map_request.response != null and hhdm_request.response != null)
    blk: {
        const memory_map_response = memory_map_request.response.?;
        const hhdm_response = hhdm_request.response.?;
        break :blk allocator.init(memory_map_response, hhdm_response.offset) catch panic();
    } else {
        @panic("No memory map or hhdm response");
    };

    const page = bitmap_allocator.allocatePage() catch @panic("Failed to allocate page");
    bitmap_allocator.freePage(page) catch @panic("Failed to free page");

    const page_block = bitmap_allocator.allocatePageBlock(0x30000) catch @panic("Failed to allocate page block");
    bitmap_allocator.freePageBlock(page_block, 0x30000) catch @panic("Failed to free page block");

    done();
}
