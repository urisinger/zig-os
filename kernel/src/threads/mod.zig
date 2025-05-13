const std = @import("std");

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

pub const Scheduler = struct {
    task_qeueue: ?*TaskQueueEntry
};


pub fn saveContext(constext: *idt.Context) void{
    const scheduler = core.context().scheduler;
    const cur_task = scheduler.task_qeueue.?;
    cur_task.task.context = constext;
}

export fn schedulerTick() callconv(.SysV) *idt.Context {
    return nextThead();
}

pub fn nextThead() *idt.Context{
    const scheduler = &core.context().scheduler;
    const current_task = scheduler.task_qeueue.?;

    const next_task = current_task.next;

    if (next_task.name) |name| {
        std.log.info("switching to task: {s}", .{name});
    }

    tss.set_rsp(next_task.task.kernel_stack);

    cpu.setCr3(@intFromPtr(next_task.task.pml4) - globals.hhdm_offset);

    scheduler.task_qeueue = next_task;
    return next_task.task.context;
}

pub fn insertTask(new_task: *TaskQueueEntry) void {
    const scheduler = &core.context().scheduler;
    const current_task = scheduler.task_qeueue;

    if (current_task) |task| {
        new_task.next = task.next;
        task.next = new_task;
    } else {
        new_task.next = new_task;
        scheduler.task_qeueue = new_task;
    }
}

pub fn createAndPopulateTask(
    allocator: std.mem.Allocator,
    entry_code: []const u8,
    name: []const u8,
) void {
    var user_vmm = uvmm.VmAllocator.init(allocator, utils.MB(1), 0x00007FFFFFFFFFFF);

    const user_pml4 = paging.createNewAddressSpace() catch unreachable;

    const entry_point = uheap.allocateUserExecutablePageWithCode(
        &user_vmm,
        user_pml4,
        entry_code,
    ) catch unreachable;

    const user_stack_bottom = uheap.allocateUserPages(&user_vmm, user_pml4, 1) catch unreachable;
    const user_stack_top = user_stack_bottom + utils.PAGE_SIZE;

    const kernel_stack = kheap.allocatePages(2) catch unreachable;

    const kernel_stack_top = kernel_stack + 2 * utils.PAGE_SIZE;
    const context_ptr: *idt.Context = @ptrFromInt(kernel_stack_top - @sizeOf(idt.Context));

    context_ptr.* = idt.Context{
        .registers = .{},
        .interrupt_num = 0,
        .error_code = 0,
        .ret_frame = .{
            .rip = entry_point,
            .cs = 0x18 | 0x3,
            .rsp = user_stack_top,
            .rflags = 0x202,
            .ss = 0x20 | 0x3,
        },
    };

    const task = allocator.create(Task) catch unreachable;

    task.* = Task{
        .context = context_ptr,
        .vma = user_vmm,
        .pml4 = user_pml4,
        .kernel_stack = kernel_stack_top,
    };

    const task_entry = allocator.create(TaskQueueEntry) catch unreachable;

    task_entry.task = task;
    task_entry.next = task_entry;
    task_entry.name = name;

    insertTask(task_entry);
}

pub export fn enterUserMode() noreturn {
    const scheduler = core.context().scheduler;
    const current_task = scheduler.task_qeueue.?;
    const task = current_task.task;

    tss.set_rsp(task.kernel_stack);
    cpu.ltr(0x28);

    cpu.setCr3(@intFromPtr(task.pml4) - globals.hhdm_offset);


    const context: *idt.Context= @ptrFromInt(task.kernel_stack - @sizeOf(idt.Context));

    const frame = &context.ret_frame;
    asm volatile (
        \\ swapgs
        \\ mov $0x23, %ax
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
