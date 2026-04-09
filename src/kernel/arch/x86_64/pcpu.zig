const root = @import("root");
const tasking = root.tasking;
const scheduler = tasking.scheduler;
const instr = @import("instr.zig");

const std = @import("std");

pub const CoreContext = struct {
    self: *CoreContext,
    kernel_stack: u64,
    // Temporary location to store the user stack pointer for user mode
    user_stack: u64,
    scheduler: scheduler.Scheduler,
    apic_id: u8,
};

pub inline fn context() *CoreContext {
    return @ptrFromInt(asm volatile ("mov %gs:0, %[ret]"
        : [ret] "=r" (-> u64),
    ));
}

const MSR_KERNEL_GS_BASE = 0xC0000102;

var cpu_0_context: CoreContext = undefined;

pub fn init() void {
    cpu_0_context.self = &cpu_0_context;

    const core_ptr = @intFromPtr(&cpu_0_context);
    instr.writeMsr(MSR_KERNEL_GS_BASE, core_ptr);
    asm volatile ("swapgs");
}
