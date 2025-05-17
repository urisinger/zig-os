const std = @import("std");
const log = std.log.scoped(.main);

const Gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false, .page_size = utils.PAGE_SIZE });

const logger = @import("logger.zig");

const utils = @import("utils.zig");
pub const panic = utils.panic;

const boot = @import("boot.zig");

const kheap = @import("memory/kernel/heap.zig");
const idt = @import("idt/idt.zig");

const apic = @import("apic/mod.zig");

const cpu = @import("cpu.zig");

pub const os = @import("os.zig");

const framebuffer = @import("display/framebuffer.zig");
const console = @import("display/console.zig");
const uvmm = @import("memory/user/vmm.zig");
const ps2 = @import("drivers/ps2.zig");

const ps2_keyboard = @import("drivers/keyboard/ps2.zig");

const gdt = @import("gdt.zig");

const scheduler = @import("scheduler/scheduler.zig");

const paging = @import("memory/kernel/paging.zig");
const uheap = @import("memory/user/heap.zig");
const core = @import("core.zig");

const elf_code align(@alignOf(std.elf.Elf64_Ehdr)) = @embedFile("user_elf").*;
const elf = @import("exec/elf.zig");
const syscall = @import("idt/syscall.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
    .page_size_max = utils.LARGE_PAGE_SIZE,
    .page_size_min = utils.PAGE_SIZE,
};

const entry_code = [_]u8{
    0x0F, 0x05, // pause
    0xeb, 0xfc, // jmp $-3
};

export fn _start() callconv(.C) noreturn {
    cpu.cli();

    framebuffer.init();
    logger.init();

    boot.init();

    gdt.init();
    core.init();

    idt.init();

    kheap.init();
    console.init();

    apic.configureLocalApic() catch @panic("failed to init apic");

    ps2.init() catch @panic("failed to initilize ps2");

    ps2_keyboard.init() catch |err| {
        log.err("Failed to initialize PS/2 keyboard: {}", .{err});
        @panic("PS/2 keyboard init failed");
    };

    syscall.init();

    const allocator = core.context().gpa.allocator();

    scheduler.insertTask(allocator, elf.elfTask(&elf_code, allocator) catch unreachable, "task_1") catch unreachable;
    scheduler.start();
    cpu.halt();
}
