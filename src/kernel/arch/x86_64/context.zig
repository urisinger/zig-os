const std = @import("std");
const root = @import("root");
const arch = root.arch;
const instr = arch.instr;
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

pub fn handler(comptime num: u8) type {
    const error_code_list = [_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 };

    const push_error = if (for (error_code_list) |value| {
        if (value == num) {
            break true;
        }
    } else false)
        ""
    else
        "push $0b10000000000000000\n";

    const push_num = std.fmt.comptimePrint("push ${} \n", .{num});

    return struct {
        pub fn handle() callconv(.naked) void {
            instr.swapgs_if_necessary();

            asm volatile (push_error ++ push_num);
            instr.pushGpr();

            asm volatile (
                \\ xor %rbp, %rbp
                \\ mov $0x10, %ax 
                \\ mov %ax, %ds
                \\ mov %ax, %es
                \\ mov %rsp, %rdi
                \\ call interruptDispatch
                \\ mov %rax, %rsp
                \\ mov $0x1B, %ax 
                \\ mov %ax, %ds
                \\ mov %ax, %es 
            );

            instr.popGpr();
            asm volatile ("add $16, %rsp");

            instr.swapgs_if_necessary();

            asm volatile ("iretq");
        }
    };
}

pub fn jumpToKernelTask(context: *const Context) noreturn {
    const frame = &context.ret_frame;

    asm volatile (
        \\ mov %[rsp_val], %%rsp 
        \\ jmp *%[rip_val]
        :
        : [rsp_val] "r" (frame.rsp),
          [rip_val] "r" (frame.rip)
        : .{ .memory = true }
    );

    unreachable;
}



pub fn jumpToUserTask(context: *const Context) noreturn {
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
        \\ iretq
        :
        : [ss] "r" (frame.ss),
          [rsp] "r" (frame.rsp),
          [rflags] "r" (frame.rflags),
          [cs] "r" (frame.cs),
          [rip] "r" (frame.rip),
        : .{ .memory = true });
    unreachable;
}
