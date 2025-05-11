const std = @import("std");

const cpu = @import("../cpu.zig");
const tss = @import("../tss.zig");
const page_table = @import("../memory/page_table.zig");
const VmaAllocator = @import("../memory/user/vmm.zig").VmAllocator;

const idt = @import("../idt/idt.zig");

const paging = @import("../memory/kernel/paging.zig");
const uvmm = @import("../memory/user/vmm.zig");
const utils = @import("../utils.zig");
const uheap = @import("../memory/user/heap.zig");

const globals = @import("../globals.zig");
const Task = struct{
    context: idt.Context,
    pml4: *page_table.PageMapping,
    vma: VmaAllocator,
    kernel_stack: u64,

    name: ?[]const u8,

};

const TaskQueueEntry = struct{
    task: Task,
    next: *TaskQueueEntry,
};

export var current_task: ?*TaskQueueEntry = undefined;


export fn saveContext() callconv(.C) void {
    if (current_task) |cur_task| {
        const context_ptr: [*]volatile const u8 = @ptrCast(idt.context);
        const dest_ptr: [*]u8 = @ptrCast(&cur_task.task.context);

        @memcpy(
            dest_ptr[0..@sizeOf(idt.Context)],
            context_ptr[0..@sizeOf(idt.Context)],
        );
    }
}


export fn contextSwitch() callconv(.C) void{
    if (current_task) |cur_task|{
        current_task = cur_task.next;

        cpu.setCr3(@intFromPtr(cur_task.next.task.pml4) - globals.hhdm_offset);
        idt.context.* = cur_task.next.task.context;

        if (cur_task.next.task.name) |name|{
            std.log.info("switching to task: {s}", .{name});
        }
    }
}

pub fn insertTask(new_task: *TaskQueueEntry) void {
    if (current_task) |task|{
        new_task.next = task.next;
        task.next = new_task;
    } else{
        new_task.next = new_task;
        current_task = new_task;
    }
}

pub fn createAndPopulateTask(
    allocator: std.mem.Allocator,
    entry_code: []const u8,
    kernel_stack: u64,
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

    const context = idt.Context{
        .registers = .{
        },
        .interrupt_num = 0,
        .error_code = 0,
        .ret_frame = .{
            .rip = entry_point,
            .cs = 0x18 | 0x3,
            .rflags = 0x202,
            .rsp = user_stack_top,
            .ss = 0x20 | 0x3,
        },
    };



    const task = Task{
        .vma = user_vmm,
        .pml4 = user_pml4,
        .context = context,
        .kernel_stack = kernel_stack,
        .name = name,
    };


    std.log.info("{}", .{task.context.ret_frame});



    const task_entry = allocator.create(TaskQueueEntry) catch unreachable;
    task_entry.task = task;
    task_entry.next = task_entry;


    insertTask(task_entry);


    std.log.info("{}", .{current_task.?.task.context.ret_frame});
}

pub export fn enterUserMode() noreturn {
    std.log.info("{}", .{current_task.?.task.context.ret_frame});
    const task = &current_task.?.task;

    tss.set_rsp(task.kernel_stack);
    cpu.ltr(0x28);

    std.log.info("{}", .{@import("../memory/kernel/paging.zig").getPaddr(@bitCast(@intFromPtr(task.pml4))) catch unreachable});

    std.log.info("{}", .{task.pml4.getPaddr(@bitCast(@intFromPtr(task.pml4))) catch unreachable});

    cpu.setCr3(@intFromPtr(task.pml4) - globals.hhdm_offset);

    std.log.info("0x{x}", .{cpu.getCr3()});



    cpu.sti();

    const frame = &task.context.ret_frame;

    asm volatile (
        \\ pushq %[ss]
        \\ pushq %[rsp]
        \\ pushq %[rflags]
        \\ pushq %[cs]
        \\ pushq %[rip]
        \\ iretq
        :
        : [ss] "r"(frame.ss),
          [rsp] "r"(frame.rsp),
          [rflags] "r"(frame.rflags),
          [cs] "r"(frame.cs),
          [rip] "r"(frame.rip)
        : "memory"
    );

    unreachable;
}
