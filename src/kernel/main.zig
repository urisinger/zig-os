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

    apic.init() catch @panic("failed to init apic");

    keyboard.Manager.init();

    ps2.init() catch @panic("failed to initilize ps2");

    keyboard.ps2.init() catch |err| {
        log.err("Failed to initialize PS/2 keyboard: {}", .{err});
        @panic("PS/2 keyboard init failed");
    };

    dev.serial.initInterrupts();

    // CBIP / VFS Demo Setup
    setupCbipDemo() catch |err| {
        log.err("Failed to setup CBIP demo: {}", .{err});
    };

    syscall.init();

    const sched = &arch.pcpu.context().scheduler;

    const init_task = sched.createUserTask(2, 0x100) catch unreachable;
    _ = sched.createKernelTask(0x1000, handler, 131) catch unreachable;

    init_task.loadElf(&elf_code) catch unreachable;

    setupCbipDemo() catch unreachable;

    sched.start();
}

pub fn handler(arg: u64) i32 {
        log.info("hi {}", .{arg});
        return 32;
}

const vfs = core.vfs;
const cbip = core.cbip;

const Stream = struct {
    write: *const fn (*anyopaque, [*]const u8, u64) callconv(.c) u64,
};

fn serial_write(_: *anyopaque, data_ptr: [*]const u8, data_len: u64) callconv(.c) u64 {
    const data = data_ptr[0..data_len];
    dev.serial.puts(data);
    return data.len;
}

var dev_vnode = vfs.Vnode.init("dev", true);
var serial_vnode = vfs.Vnode.init("serial", false);

const serial_vtable = [_]*const anyopaque{
    @ptrCast(&serial_write),
};

fn setupCbipDemo() !void {
    const stream_id = cbip.generateID("io.os.v1.Stream", Stream);
    log.info("id: 0x{x}", .{stream_id});
    const stream_canonical = cbip.getCanonicalString("io.os.v1.Stream", Stream);
    
    try cbip.announce("io.os.v1.Stream", stream_id, stream_canonical);
    
    try serial_vnode.cbip_vnode.bind(stream_id, &serial_vtable);
    
    try vfs.mount("/dev", &dev_vnode);
    try vfs.mount("/dev/serial", &serial_vnode);
}

pub export fn _start() callconv(.c) noreturn {
    arch.entry();
    unreachable;
}
