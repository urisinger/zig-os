const std = @import("std");
const log = std.log.scoped(.scheduler);
const root = @import("root");
const elf = @import("exec/elf.zig");

const arch = root.arch;
const Context = arch.context.Context;

const Task = @import("task.zig").Task;

const mem = root.mem;
const page_table = mem.page_table;
const VmaAllocator = mem.user.vmm.VmAllocator;
const kheap = mem.kernel.heap;
const paging = mem.kernel.paging;
const uvmm = mem.user.vmm;
const utils = root.common.utils;
const uheap = mem.user.heap;

pub const TaskQueueEntry = extern struct {
    task: *Task,
    next: *TaskQueueEntry,
};

pub const Scheduler = extern struct {
    task_qeueue: ?*TaskQueueEntry,
    const Self = @This();

    pub fn nextTask(self: *Self) *Context {
        const current_task = self.task_qeueue.?;
        const next_task = current_task.next;

        next_task.task.load();

        self.task_qeueue = next_task;

        return next_task.task.context;
    }

    pub fn insertTask(self: *Self) !*Task {
        const entry_slab = try kheap.get_slab_cache(TaskQueueEntry);
        const task_slab = try kheap.get_slab_cache(Task);
        const queue_entry = try entry_slab.alloc();

        const task = try task_slab.alloc();

        queue_entry.task = task;

        const current_task = self.task_qeueue;

        if (current_task) |cur_task| {
            queue_entry.next = cur_task.next;
            cur_task.next = queue_entry;
        } else {
            queue_entry.next = queue_entry;
            self.task_qeueue = queue_entry;
        }
        return task;
    }

    pub fn start(self: *Self) noreturn {
        const current_task = self.task_qeueue.?;
        const task = current_task.task;

        task.load();

        const context: *Context = @ptrFromInt(task.kernel_stack - @sizeOf(Context));
        arch.jumpToUserMode(context);
    }

    pub fn saveContext(self: *Self, context: *Context) void {
        const cur_task = self.task_qeueue.?;
        cur_task.task.context = context;
    }
};
