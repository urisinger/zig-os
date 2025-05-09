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

const ps2_keyboard = @import("drivers/keyboard/ps2.zig");

const gdt = @import("gdt.zig");

const threads = @import("threads/mod.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};

export fn _start() callconv(.C) noreturn {

    cpu.cli();
    framebuffer.init();
    console.init();
    logger.init();
    boot.init();

    gdt.init();
    kheap.init();

    idt.init();

    apic.configureLocalApic() catch @panic("failed to init apic");


    ps2.init() catch @panic("failed to initilize ps2");

    ps2_keyboard.init() catch |err| {
        std.log.err("Failed to initialize PS/2 keyboard: {}", .{err});
        @panic("PS/2 keyboard init failed");
    };
 

    const entry_code = [_]u8{
        0xf3, 0x90,   // pause
        0xeb, 0xfd,   // jmp $-3 (back to pause)
    };
    
    const entry_point = kheap.allocateExecutablePageWithCode(&entry_code) catch unreachable;
    const user_stack_bottom = kheap.allocatePagesWithFlags(1, .{ .present = true, .read_write = .read_write, .user_supervisor = .user}) catch unreachable;

    const user_stack_top = user_stack_bottom + utils.PAGE_SIZE;

    threads.enterUserMode(entry_point, user_stack_top, cpu.getRsp()); }
