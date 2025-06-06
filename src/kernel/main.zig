const std = @import("std");
const log = std.log.scoped(.main);

const logger = @import("logger.zig");

const utils = @import("utils.zig");
pub const panic = logger.panic_handler;

const boot = @import("boot.zig");

const kheap = @import("memory/kernel/heap.zig");
const idt = @import("idt/idt.zig");

const apic = @import("apic/mod.zig");

const cpu = @import("cpu.zig");

pub const os = @import("os.zig");

const framebuffer = @import("display/framebuffer.zig");
const console = @import("display/console.zig");
const ps2 = @import("drivers/ps2.zig");

const ps2_keyboard = @import("drivers/keyboard/ps2.zig");

const gdt = @import("gdt.zig");

const scheduler = @import("scheduler/scheduler.zig");

const core = @import("core.zig");

const elf_code align(@alignOf(std.elf.Elf64_Ehdr)) = @embedFile("user_elf").*;
const elf = @import("exec/elf.zig");
const syscall = @import("idt/syscall.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
    .page_size_max = utils.PAGE_SIZE,
    .page_size_min = utils.PAGE_SIZE,
};

const entry_code = [_]u8{
    0x0F, 0x05, // pause
    0xeb, 0xfc, // jmp $-3
};

export fn _start() callconv(.C) noreturn {
    asm volatile (
        \\ cli
        \\ xor %rbp, %rbp
        \\ call kmain
        \\ ud2
    );
    unreachable;
}

export fn kmain() noreturn {
    framebuffer.init();
    logger.init();

    boot.init();

    gdt.init();

    idt.init();

    kheap.init();

    core.init();
    console.init();

    apic.configureLocalApic() catch @panic("failed to init apic");

    ps2.init() catch @panic("failed to initilize ps2");

    ps2_keyboard.init() catch |err| {
        log.err("Failed to initialize PS/2 keyboard: {}", .{err});
        @panic("PS/2 keyboard init failed");
    };

    syscall.init();

    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;
    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;
    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;
    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;
    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;

    scheduler.start();
}
