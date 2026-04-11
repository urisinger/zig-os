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

pub export fn _start() callconv(.c) noreturn {
    arch.entry();
    unreachable;
}

const vfs = core.vfs;
const cbip = core.cbip;

const Stream = struct {
    pub const NAME: []const u8 = "io.os.v1.Stream";
    write: *const fn (ctx: *anyopaque, data_ptr: [*]const u8, data_len: u64) u64,
};

// 2. Define the Driver Structure (Embedding the Vnode)
const SerialPort = struct {
    vnode: vfs.Vnode,
    // Add hardware-specific fields here (e.g. base_addr: usize)

    pub fn init(name: []const u8) SerialPort {
        return .{
            .vnode = vfs.Vnode.initDevice(name, getInterface),
        };
    }

    // This is the pivot logic for this specific hardware
    fn getInterface(vnode_ptr: *vfs.Vnode, id: u64) cbip.InterfaceResult {
        // Recover the SerialPort pointer from the Vnode member
        const self: *SerialPort = @fieldParentPtr("vnode", vnode_ptr);
        
        if (id == cbip.generateID(Stream)) {
            return .{
                .vtable = &serial_vtable,
                .context = self, // The context is the SerialPort struct itself
                .status = 0,
            };
        }
        return .{ .vtable = null, .context = null, .status = 404 };
    }
};

// 3. Implement the Interface Function
fn serial_write(ctx: *anyopaque, data_ptr: [*]const u8, data_len: u64) u64 {
    const self: *SerialPort = @ptrCast(@alignCast(ctx));
    _ = self; 
    
    const data = data_ptr[0..data_len];
    dev.serial.puts(data); 
    return data.len;
}

var dev_vnode = vfs.Vnode.initDir("dev");
var serial_dev = SerialPort.init("serial");

const serial_vtable = cbip.flatten(Stream{
    .write = serial_write,
});

pub fn setupCbipDemo() !void {
    // Announce the interface to the kernel's registry
    try cbip.announce(Stream.NAME, cbip.generateID(Stream), cbip.getCanonicalString(Stream));
    
    // Mount the structures
    try vfs.mount("/", &dev_vnode); // Mount dev at root
    try vfs.mount("/dev", &serial_dev.vnode); // Mount embedded vnode
    
    std.log.info("VFS initialized. /dev/serial is ready.", .{});
}
