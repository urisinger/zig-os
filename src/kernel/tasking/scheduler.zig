const std = @import("std");
const log = std.log.scoped(.scheduler);
const root = @import("root");
const elf = @import("exec/elf.zig");

const arch = root.arch;
const tss = arch.tss;
const idt = arch.idt.idt;

const mem = root.mem;
const page_table = mem.page_table;
const VmaAllocator = mem.user.vmm.VmAllocator;
const kheap = mem.kernel.heap;
const paging = mem.kernel.paging;
const uvmm = mem.user.vmm;
const utils = root.common.utils;
const uheap = mem.user.heap;

const globals = root.common.globals;

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
    const scheduler = arch.getContext().scheduler;
    const cur_task = scheduler.task_qeueue.?;
    cur_task.task.context = constext;
}

pub fn schedulerTick() callconv(.{ .x86_64_sysv = .{}}) *idt.Context {
    return nextTask();
}

fn nextTask() *idt.Context {
    const context = arch.getContext();
    const scheduler = &context.scheduler;
    const current_task = scheduler.task_qeueue.?;

    const next_task = current_task.next;

    if (next_task.name) |name| {
        log.info("switching to task: {s}", .{name});
    }

    tss.set_rsp(next_task.task.kernel_stack);
    const pml4 = next_task.task.pml4;

    arch.cpu.setCr3(@intFromPtr(pml4) - globals.hhdm_offset);

    context.kernel_stack = next_task.task.kernel_stack;
    context.current_task = next_task.task;
    scheduler.task_qeueue = next_task;
    return next_task.task.context;
}

pub fn insertTask(task: *Task, name: []const u8) !void {
    const slab = try kheap.get_slab_cache(TaskQueueEntry);
    const new_task = try slab.alloc();
    log.info("new_task: 0x{x}", .{@intFromPtr(new_task)});

    new_task.task = task;
    new_task.name = name;

    const context = arch.getContext();
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

pub fn start() noreturn {
    const scheduler = arch.getContext().scheduler;
    const current_task = scheduler.task_qeueue.?;
    const task = current_task.task;

    tss.set_rsp(task.kernel_stack);
    arch.cpu.ltr(0x28);

    arch.cpu.setCr3(@intFromPtr(task.pml4) - globals.hhdm_offset);

    const context: *idt.Context = @ptrFromInt(task.kernel_stack - @sizeOf(idt.Context));

    log.info("starting scheduler", .{});
    arch.jumpToUserMode(context);
}
