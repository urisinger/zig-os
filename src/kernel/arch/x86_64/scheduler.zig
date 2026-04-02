const root = @import("root");
const idt = root.arch.idt.idt;

pub fn jumpToUserMode(context: *const idt.Context) noreturn {
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
