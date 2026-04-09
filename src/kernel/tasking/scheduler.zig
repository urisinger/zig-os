const std = @import("std");
const log = std.log.scoped(.scheduler);
const root = @import("root");
const arch = root.arch;
const Context = arch.context.Context;

const Task = @import("task.zig").Task;
const UserTask = @import("task.zig").UserTask;
const KernelTask = @import("task.zig").KernelTask;

const mem = root.mem;
const kheap = mem.kernel.heap;
const utils = root.common.utils;
const pmm = mem.pmm;

pub const TaskQueueEntry = extern struct {
    task: *Task,
    next: *TaskQueueEntry,
    prev: *TaskQueueEntry,
};

pub const Scheduler = extern struct {
    task_queue: ?*TaskQueueEntry,
    const Self = @This();

    pub fn dump(self: *Scheduler) void {

        if (self.task_queue == null) {
            log.info("task queue is empty", .{});
            return;
        }

        const start_task = self.task_queue.?;
        var current = start_task;
        var i: usize = 0;

        log.info("---- Task Queue Dump ----", .{});

        while (true) {
            const task = current.task;

            log.info(
                "[{}] task=*{x}, kind={s}, state={s}, kstack=0x{x}",
                .{
                    i,
                    @intFromPtr(task),
                    @tagName(task.kind),
                    @tagName(task.state),
                    task.kernel_stack,
                },
            );

            current = current.next;
            i += 1;

            // Stop if we loop back
            if (current == start_task) break;

            // Safety guard (in case of corruption)
            if (i > 1024) {
                log.err("task queue seems corrupted (loop > 1024)", .{});
                break;
            }
        }

        log.info("--------------------------", .{});
    }

    // ---------------------
    // Scheduler Core
    // ---------------------
    pub fn nextTask(self: *Self) ?*Context {
        if (self.task_queue == null) return null;

        self.dump();

        var current = self.task_queue.?;
        var next = current.next;

        // Skip and free dead tasks
        while (current.task.state == .Dead) {
            self.removeEntry(current);
            current.task.free() catch {
                log.err("failed to free task", .{});
            };

            if (self.task_queue == null) return null;
            current = next;
            next = next.next;
        }


        next.task.load();
        self.task_queue = next;
        return next.task.context;
    }

    pub fn start(self: *Self) noreturn {
        var current = self.task_queue.?;

        // Immediately skip any dead tasks
        while (current.task.state == .Dead) : (current = current.next) {
            self.removeEntry(current);
            current.task.free() catch {
                log.err("failed to free task", .{});
            };

            if (self.task_queue == null) unreachable;
        }

        current.task.load();
        current.task.start();
    }
    pub fn currentTask(self: *const Self) ?*Task {
        return if (self.task_queue) |q| q.task else null;
    }

    pub fn saveContext(self: *Self, ctx: *Context) void {
        const cur = self.task_queue.?;
        cur.task.context = ctx;
    }

    // ---------------------
    // Task Creation
    // ---------------------
    pub fn createUserTask(self: *Self, kernel_stack_pages: usize, user_stack_pages: usize) !*UserTask {
        const entry_slab = try kheap.get_slab_cache(TaskQueueEntry);
        const user_slab = try kheap.get_slab_cache(UserTask);

        const queue_entry = try entry_slab.alloc();
        const user_task = try user_slab.alloc();

        try user_task.init(kernel_stack_pages, user_stack_pages);
        user_task.base.state = .Runnable;

        queue_entry.task = &user_task.base;
        queue_entry.next = queue_entry;
        queue_entry.prev = queue_entry;

        self.insertEntry(queue_entry);
        return user_task;
    }

    pub fn createKernelTask(self: *Self, kernel_stack_pages: usize, entry_fn: fn (u64) i32, arg: u64) !*KernelTask {
        const entry_slab = try kheap.get_slab_cache(TaskQueueEntry);
        const kernel_slab = try kheap.get_slab_cache(KernelTask);

        const queue_entry = try entry_slab.alloc();
        const kernel_task = try kernel_slab.alloc();

        try kernel_task.init(kernel_stack_pages, entry_fn, arg);
        kernel_task.base.state = .Runnable;

        queue_entry.task = &kernel_task.base;
        queue_entry.next = queue_entry;
        queue_entry.prev = queue_entry;

        self.insertEntry(queue_entry);
        return kernel_task;
    }

    // ---------------------
    // Queue Management (Circular)
    // ---------------------
    fn insertEntry(self: *Self, entry: *TaskQueueEntry) void {
        if (self.task_queue) |head| {
            const tail = head.prev;

            entry.next = head;
            entry.prev = tail;

            tail.next = entry;
            head.prev = entry;
        } else {
            entry.next = entry;
            entry.prev = entry;
            self.task_queue = entry;
        }
    }

    pub fn removeEntry(self: *Self, entry: *TaskQueueEntry) void {
        if (entry.next == entry) {
            self.task_queue = null;
        } else {
            entry.prev.next = entry.next;
            entry.next.prev = entry.prev;
            if (self.task_queue == entry) self.task_queue = entry.next;
        }
    }

    pub fn exitCurrentTask(self: *Self) noreturn {
        const entry = self.task_queue.?;
        entry.task.state = .Dead;
        arch.instr.int(0x24);
        unreachable;
    }
};
