const scheduler = @import("scheduler/scheduler.zig");
const cpu = @import("cpu.zig");

const std = @import("std");

const Gpa = std.heap.DebugAllocator(.{ .backing_allocator_zeroes = false, .thread_safe = false });

const CoreContext = struct {
    self: *CoreContext,
    kernel_stack: u64,
    // Temporary location to store the user stack pointer for user mode
    user_stack: u64,
    current_task: *scheduler.Task,
    scheduler: scheduler.Scheduler,
    gpa: Gpa,
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
    cpu_0_context.gpa = Gpa{};

    const core_ptr = @intFromPtr(&cpu_0_context);
    cpu.writeMsr(MSR_KERNEL_GS_BASE, core_ptr);
    asm volatile ("swapgs");
}
