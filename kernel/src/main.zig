const std = @import("std");
const log = std.log;

const Gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false });

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

const threads = @import("threads/mod.zig");

const paging = @import("memory/kernel/paging.zig");
const uheap = @import("memory/user/heap.zig");

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
    .log_level = .debug,
};


const entry_code = [_]u8{
    0xf3, 0x90, // pause
    0xeb, 0xfd, // jmp $-3
};


export fn _start() callconv(.C) noreturn {
    cpu.cli();
    logger.init();
    boot.init();

    gdt.init();
    kheap.init();

    framebuffer.init();
    console.init();

    idt.init();

    apic.configureLocalApic() catch @panic("failed to init apic");

    ps2.init() catch @panic("failed to initilize ps2");

    ps2_keyboard.init() catch |err| {
        std.log.err("Failed to initialize PS/2 keyboard: {}", .{err});
        @panic("PS/2 keyboard init failed");
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = false }){};
    const allocator = gpa.allocator();

    var user_vmm = uvmm.VmAllocator.init(allocator, utils.MB(1), 0x00007FFFFFFFFFFF);

    const user_pml4 = paging.createNewAddressSpace() catch unreachable;

    cpu.setCr3(@intFromPtr(user_pml4) - @import("globals.zig").hhdm_offset);


    const offset = TOTAL_SIZE - loop_code.len;
    @memcpy(entry_code[offset..], &loop_code);



    const entry_point = uheap.allocateUserExecutablePageWithCode(&user_vmm, user_pml4, &entry_code) catch unreachable;

    const user_stack_bottom = uheap.allocateUserPages(&user_vmm, user_pml4, 1) catch unreachable;

    const user_stack_top = user_stack_bottom + utils.PAGE_SIZE;
    std.log.info("hh", .{});

    threads.enterUserMode(entry_point, user_stack_top, cpu.getRsp());
}
