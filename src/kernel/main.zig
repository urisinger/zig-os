const std = @import("std");
const log = std.log.scoped(.main);

// Export modules for the rest of the kernel to use via @import("root")
pub const common = @import("common/mod.zig");
pub const arch = @import("arch/x86_64/mod.zig");
pub const mem = @import("mem/mod.zig");
pub const dev = @import("dev/mod.zig");
pub const tasking = @import("tasking/mod.zig");
pub const core = @import("core/mod.zig");

const klog = core.klog;
const boot = core.boot;
const pcpu = arch.pcpu;
const syscall = arch.idt.syscall;
const gdt = arch.gdt;
const idt = arch.idt.table;
const apic = arch.apic;
const istr = arch.istr;
const kheap = mem.kernel.heap;
const framebuffer = dev.display.framebuffer;
const console = dev.display.console;
const ps2 = dev.ps2;
const keyboard = dev.keyboard;
const scheduler = tasking.scheduler;
const elf = tasking.exec.elf;

pub const panic = klog.panic_handler;
pub const os = core.os;

const elf_code align(@alignOf(std.elf.Elf64_Ehdr)) = @embedFile("user_elf").*;

pub const std_options: std.Options = .{
    .logFn = klog.logFn,
    .log_level = .debug,
    .page_size_max = common.utils.PAGE_SIZE,
    .page_size_min = common.utils.PAGE_SIZE,
};

export fn kmain() noreturn {
    framebuffer.init();
    klog.init();



    boot.init();


    gdt.init();

    idt.init();

    arch.init(); // per_cpu init

    kheap.init();


    console.init();

    apic.configureLocalApic() catch @panic("failed to init apic");

    ps2.init() catch @panic("failed to initilize ps2");

    keyboard.ps2.init() catch |err| {
        log.err("Failed to initialize PS/2 keyboard: {}", .{err});
        @panic("PS/2 keyboard init failed");
    };

    syscall.init();

    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_1") catch unreachable;
    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;
    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;
    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;
    scheduler.insertTask(elf.elfTask(&elf_code) catch unreachable, "task_3") catch unreachable;

    scheduler.start();
}

pub export fn _start() callconv(.c) noreturn {
    arch.entry();
    unreachable;
}


