const cpu = @import("../cpu.zig");
const tss = @import("../tss.zig");



const std = @import("std");

pub fn enterUserMode(entry_point: u64, user_stack_top: u64, kernel_stack_top: u64) noreturn {
    const USER_CS: u64 = 0x18 | 0x3;
    const USER_SS: u64 = 0x20 | 0x3;


    tss.set_rsp(kernel_stack_top);
    cpu.ltr(0x28);

    cpu.sti();


    const asm_code = std.fmt.comptimePrint(
        \\ mov ${}, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ xchg %%bx, %%bx
        \\
        \\ pushq ${}
        \\ pushq %[stack]
        \\ pushfq
        \\ pushq ${}
        \\ pushq %[entry]
        \\ iretq
        ,
        .{  USER_SS, USER_SS,  USER_CS }
    );

    asm volatile (asm_code
        :
        : [entry] "r"(entry_point),
          [stack] "r"(user_stack_top)
        : "rax", "memory"
    );

    unreachable;
}

