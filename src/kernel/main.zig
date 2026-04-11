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

    syscall.init();

    vfs.init() catch unreachable;

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

pub const Stream = struct {
    pub const NAME: []const u8 = "io.os.v1.Stream";
    pub const ID: u64 = cbip.generateID(Stream);
    write: *const fn (ctx: *anyopaque, data_ptr: [*]const u8, data_len: u64) u64,
};

// 1. Define the Driver Structure (Embedding the Inode)
const SerialPort = struct {
    // Now embeds Mount, which has Inode as its first field
    mount: vfs.Mount,

    pub fn create() !*SerialPort {
        const self = try mem.allocator.create(SerialPort);
        self.* = .{
            .mount = .{
                .inode = .{
                    .get_interface = getInterface,
                    .deinit_fn = deinit,
                },
                .ops = .{
                    .lookup = serial_lookup,
                    .create = serial_create,
                },
            },
        };
        return self;
    }

    // Recovering context: Inode -> Mount -> SerialPort
    fn getInterface(inode_ptr: *cbip.Inode, id: u64) cbip.InterfaceResult {
        const m = vfs.Mount.fromInode(inode_ptr);
        const self: *SerialPort = @fieldParentPtr("mount", m);
        log.debug("0x{x}", .{Stream.ID});

        if (id == Stream.ID) {
            return .{
                .vtable = &serial_vtable,
                .context = &self.mount.inode,
                .status = 0,
            };
        }
        return .{ .vtable = null, .context = null, .status = 404 };
    }

    fn serial_lookup(_: *vfs.Mount, _: *cbip.Inode, _: []const u8) u64 {
        return 0; // No children here
    }

    fn serial_create(_: *vfs.Mount, _: *cbip.Inode, _: []const u8) u64 {
        return 0; // Cannot create files inside a serial port
    }

    fn deinit(inode_ptr: *cbip.Inode) void {
        const m = vfs.Mount.fromInode(inode_ptr);
        const self: *SerialPort = @fieldParentPtr("mount", m);
        mem.allocator.destroy(self);
    }
};

fn serial_write(ctx: *anyopaque, data_ptr: [*]const u8, data_len: u64) u64 {
    const self: *SerialPort = @ptrCast(@alignCast(ctx));
    _ = self;

    const data = data_ptr[0..data_len];

    dev.serial.puts(data);

    return data.len;
}

const serial_vtable = cbip.flatten(Stream{
    .write = serial_write,
});

pub fn setupCbipDemo() !void {
    log.info("Starting CBIP Demo Setup...", .{});

    cbip.announce(Stream.NAME, cbip.generateID(Stream), cbip.getCanonicalString(Stream)) catch |err| {
        log.err("CBIP Announcement failed: {any}", .{err});
        return err;
    };

    log.info("Creating /dev directory...", .{});
    _ = vfs.mkdir("/dev") catch |err| {
        if (err == error.AlreadyExists) {
            log.warn("/dev already exists, proceeding...", .{});
        } else {
            log.err("mkdir /dev failed: {any}", .{err});
            return err;
        }
    };

    log.debug("/dev is :{?}", .{vfs.lookup("/dev")});

    log.info("Initializing SerialPort driver...", .{});
    const serial_drv = SerialPort.create() catch |err| {
        log.err("SerialPort creation failed: {any}", .{err});
        return err;
    };

    log.info("Mounting serial_drv to /dev/serial...", .{});
    vfs.mount("/dev", "serial", &serial_drv.mount) catch |err| {
        log.err("Mount failed: {any}. Check if /dev actually exists.", .{err});
        return err;
    };

    log.info("VFS setup complete. /dev/serial is active.", .{});
}
