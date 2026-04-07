const std = @import("std");
const root = @import("root");
const tasking = root.tasking;
const scheduler = tasking.scheduler;

pub const Registers = packed struct {
    r15: u64 = 15,
    r14: u64 = 14,
    r13: u64 = 13,
    r12: u64 = 12,
    r11: u64 = 11,
    r10: u64 = 10,
    r9: u64 = 9,
    r8: u64 = 8,
    rdi: u64 = 7,
    rsi: u64 = 6,
    rbp: u64 = 5,
    rdx: u64 = 4,
    rcx: u64 = 3,
    rbx: u64 = 2,
    rax: u64 = 1,
};

pub const IretFrame = packed struct {
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const Context = packed struct {
    registers: Registers,
    // this will be pushed by macro isrGenerate
    interrupt_num: u64,
    // this will be pushed by macro isrGenerate
    error_code: u64,
    // In Long Mode, the error code is padded with zeros to form a 64-bit push, so that it can be popped like any other value.

    // CPU status
    ret_frame: IretFrame,
};

const idt_size = 256;
pub var handlers: [idt_size]?*const fn (*volatile Context) void = init: {
    var initial_value: [idt_size]?*const fn (*volatile Context) void = undefined;
    for (0..idt_size) |index| {
        initial_value[index] = null;
    }
    break :init initial_value;
};

export fn interruptDispatch(context: *Context) callconv(.{ .x86_64_sysv = .{}}) *Context {
    scheduler.saveContext(context);
    if (handlers[context.interrupt_num]) |handler| {
        handler(context);
    } else {
        const log = std.log.scoped(.idt);
        log.err("Unhandled expetion 0x{X} err=0b{b}", .{ context.interrupt_num, @as(u32, @intCast(context.error_code)) });
        @panic("Unhandled exeption");
    }
    return scheduler.schedulerTick();
}

pub fn jumpToUserMode(context: *const Context) noreturn {
    const frame = &context.ret_frame;
    asm volatile (
        \\ swapgs
        \\ mov $0x1B, %ax
        \\ mov %ax, %ds
        \\ mov %ax, %es
        \\ pushq %[ss]
        \\ pushq %[rsp]
        \\ pushq %[rflags]
        \\ pushq %[cs]
        \\ pushq %[rip]
        \\ sti
        \\ iretq
        :
        : [ss] "r" (frame.ss),
          [rsp] "r" (frame.rsp),
          [rflags] "r" (frame.rflags),
          [cs] "r" (frame.cs),
          [rip] "r" (frame.rip),
        : .{ .memory = true }
    );
    unreachable;
}
