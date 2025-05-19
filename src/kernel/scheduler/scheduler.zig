const std = @import("std");
const log = std.log.scoped(.scheduler);
const elf = @import("../exec/elf.zig");

const cpu = @import("../cpu.zig");
const tss = @import("../tss.zig");
const page_table = @import("../memory/page_table.zig");
const VmaAllocator = @import("../memory/user/vmm.zig").VmAllocator;

const kheap = @import("../memory/kernel/heap.zig");
const idt = @import("../idt/idt.zig");

const paging = @import("../memory/kernel/paging.zig");
const uvmm = @import("../memory/user/vmm.zig");
const utils = @import("../utils.zig");
const uheap = @import("../memory/user/heap.zig");

const globals = @import("../globals.zig");

const core = @import("../core.zig");

pub const Task = struct {
    context: *idt.Context,
    pml4: *page_table.PageMapping,
    vma: VmaAllocator,
    kernel_stack: u64,
};

pub const TaskQueueEntry = struct {
    task: *Task,
    next: *TaskQueueEntry,
    name: ?[]const u8,
};

pub const Scheduler = struct { task_qeueue: ?*TaskQueueEntry };

pub fn saveContext(constext: *idt.Context) void {
    const scheduler = core.context().scheduler;
    const cur_task = scheduler.task_qeueue.?;
    cur_task.task.context = constext;
}

pub fn schedulerTick() callconv(.SysV) *idt.Context {
    return nextTask();
}

fn nextTask() *idt.Context {
    const context = core.context();
    const scheduler = &context.scheduler;
    const current_task = scheduler.task_qeueue.?;

    const next_task = current_task.next;

    if (next_task.name) |name| {
        log.info("switching to task: {s}", .{name});
    }

    tss.set_rsp(next_task.task.kernel_stack);

    cpu.setCr3(@intFromPtr(next_task.task.pml4) - globals.hhdm_offset);

    context.kernel_stack = next_task.task.kernel_stack;
    context.current_task = next_task.task;
    scheduler.task_qeueue = next_task;
    return next_task.task.context;
}

pub fn insertTask(allocator: std.mem.Allocator, task: *Task, name: []const u8) !void {
    const new_task = try allocator.create(TaskQueueEntry);

    new_task.task = task;
    new_task.name = name;

    const context = core.context();
    const scheduler = &context.scheduler;
    const current_task = scheduler.task_qeueue;

    if (current_task) |cur_task| {
        new_task.next = cur_task.next;
        cur_task.next = new_task;
    } else {
        new_task.next = new_task;
        scheduler.task_qeueue = new_task;
        context.current_task = new_task.task;
        context.kernel_stack = new_task.task.kernel_stack;
    }
}

pub export fn start() noreturn {
    const scheduler = core.context().scheduler;
    const current_task = scheduler.task_qeueue.?;
    const task = current_task.task;

    tss.set_rsp(task.kernel_stack);
    cpu.ltr(0x28);

    cpu.setCr3(@intFromPtr(task.pml4) - globals.hhdm_offset);

    const context: *idt.Context = @ptrFromInt(task.kernel_stack - @sizeOf(idt.Context));

    const frame = &context.ret_frame;

    log.info("starting scheduler", .{});
    asm volatile (
        \\ swapgs
        \\ xchg %bx, %bx
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
        : "memory"
    );

    unreachable;
}
