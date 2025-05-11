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
    vma: VmaAllocator,
    pml4: *page_table.PageMapping,
    context: idt.Context,
    kernel_stack: u64,

    name: ?[]const u8,

};

const TaskQueueEntry = struct{
    task: Task,
    next: *TaskQueueEntry,
};

var current_task: ?*TaskQueueEntry = undefined;

export fn saveContext() void{
    
    if (current_task) |cur_task|{
    cur_task.task.context = idt.context.*;
    }
}

export fn contextSwitch() void{
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

    cpu.setCr3(@intFromPtr(user_pml4) - globals.hhdm_offset);

    const entry_point = uheap.allocateUserExecutablePageWithCode(
        &user_vmm,
        user_pml4,
        entry_code,
    ) catch unreachable;

    const user_stack_bottom = uheap.allocateUserPages(&user_vmm, user_pml4, 1) catch unreachable;
    const user_stack_top = user_stack_bottom + utils.PAGE_SIZE;

    const context = idt.Context{
        .registers = .{
            .rsp = user_stack_top,
            // everything else zero-initialized
        },
        .interrupt_num = 0,
        .error_code = 0,
        .rip = entry_point,
        .cs = 0x18 | 0x3,
        .rflags = 0x202,
        .rsp = user_stack_top,
        .ss = 0x20 | 0x3,
    };

    const task = Task{
        .vma = user_vmm,
        .pml4 = user_pml4,
        .context = context,
        .kernel_stack = kernel_stack,
        .name = name,
    };

    const task_entry = allocator.create(TaskQueueEntry) catch unreachable;
    task_entry.* = TaskQueueEntry{
        .task = task,
        .next = task_entry, // for round-robin single entry case
    };

    insertTask(task_entry);
}




pub fn enterUserMode() noreturn {
    const USER_CS: u64 = 0x18 | 0x3;
    const USER_SS: u64 = 0x20 | 0x3;

    const task = &current_task.?.task;
    const ctx = &task.context;

    // Set up TSS to point to the kernel stack for this task
    tss.set_rsp(task.kernel_stack);
    cpu.ltr(0x28); // Optional: only once after boot, not every time

    // Enable interrupts before entering user mode
    cpu.sti();

    // Inline assembly to switch to user mode with iretq
    const asm_code = std.fmt.comptimePrint(
        \\ mov ${}, %%ax
        \\ mov %%ax, %%ds
        \\ mov %%ax, %%es
        \\ mov %%ax, %%fs
        \\ mov %%ax, %%gs
        \\ xchg %%bx, %%bx
        \\
        \\ pushq ${}
        \\ pushq %[user_rsp]
        \\ pushfq
        \\ pushq ${}
        \\ pushq %[user_rip]
        \\ iretq
        ,
        .{ USER_SS, USER_SS, USER_CS }
    );

    asm volatile (asm_code
        :
        : [user_rip] "r"(ctx.rip),
          [user_rsp] "r"(ctx.rsp)
        : "rax", "memory"
    );

    unreachable;
}

