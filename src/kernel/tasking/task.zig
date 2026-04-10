const root = @import("root");
const std = @import("std");
const elf = @import("exec/elf.zig");

const arch = root.arch;
const tss = arch.tss;
const Context = arch.context.Context;
const globals = root.common.globals;

const mem = root.mem;
const paging = mem.kernel.paging;
const page_table = mem.page_table;
const vmm = mem.user.vmm;
const VmAllocator = vmm.VmAllocator;
const utils = root.common.utils;
const pmm = mem.pmm;
const uheap = mem.user.heap;

pub const TaskType = enum { Kernel, User };
pub const TaskState = enum { Runnable, Sleeping, Dead };

pub const Task = struct {
    kind: TaskType,
    state: TaskState,
    context: *Context,
    kernel_stack: u64,
    kernel_stack_pages: usize, // track for freeing

    pub fn asUser(self: *Task) ?*UserTask {
        if (self.kind != .User) return null;
        return @fieldParentPtr("base", self);
    }

    pub fn asKernel(self: *Task) ?*KernelTask {
        if (self.kind != .Kernel) return null;
        return @fieldParentPtr("base", self);
    }

    pub fn start(self: *Task) noreturn {

        arch.instr.ltr(0x28);
        switch (self.kind) {
            .User => arch.jumpToUserTask(self.context),
            .Kernel => arch.jumpToKernelTask(self.context),
        }
    }

    pub fn load(self: *Task) void {
        tss.set_rsp(self.kernel_stack);
        arch.getContext().kernel_stack = self.kernel_stack;

        if (self.kind == .User) {
            arch.instr.setCr3(@intFromPtr(self.asUser().?.pml4) - globals.hhdm_offset);
        }
    }

    /// Free the task and all its memory
    pub fn free(self: *Task) !void {
        // Free kernel stack
        try pmm.freePageBlock(self.kernel_stack - self.kernel_stack_pages * utils.PAGE_SIZE, self.kernel_stack_pages);

        // Free based on type
        switch (self.kind) {
            .Kernel => {
                const slab = root.mem.kernel.slab.get_slab_cache(KernelTask) catch return;
                slab.free(@ptrCast(self));
            },
            .User => {
                const utask = self.asUser().?;
                utask.vma.deinit(); // free all VMA allocations
                try utask.pml4.deinit(); // free PML4
                const slab = root.mem.kernel.slab.get_slab_cache(UserTask) catch return;
                slab.free(utask);
            },
        }
    }
};

pub export fn kernelTaskEntry() noreturn {
    arch.instr.sti();
    const core = arch.getContext();
    const task = (core.scheduler.currentTask() orelse unreachable).asKernel() orelse unreachable;

    const exit = task.entry(task.arg);
    std.log.debug("thread exited with exit code: {}", .{exit});

    core.scheduler.exitCurrentTask();
    unreachable;
}

// The actual target of your context switch
pub fn kernelTaskTrampoline() callconv(.naked) noreturn {
    // 1. Ensure stack alignment (x86_64 ABI requires 16-byte alignment before a call)
    // 2. Call the Zig logic function
    asm volatile (
        \\ xor %rbp, %rbp      # Clear frame pointer for clean backtraces
        \\ call kernelTaskEntry
    );
}

pub const UserTask = struct {
    base: Task,

    pml4: *page_table.PageMapping,
    vma: VmAllocator,

    pub fn init(self: *UserTask, kernel_stack_pages: usize, user_stack_pages: usize) !void {
        self.base.kind = .User;
        self.base.state = .Runnable;
        self.base.kernel_stack_pages = kernel_stack_pages;

        // Kernel stack
        const kstack_base = try pmm.allocatePageBlock(kernel_stack_pages, .@"1") + globals.hhdm_offset;
        self.base.kernel_stack = kstack_base + kernel_stack_pages * utils.PAGE_SIZE;

        // Address space
        self.pml4 = try paging.createNewAddressSpace();
        self.vma = try VmAllocator.init(utils.MB(1), 0x00007FFFFFFFFFFF);

        // User stack allocation via VMA
        const ustack_bottom = try self.vma.allocate(
            user_stack_pages * utils.PAGE_SIZE,
            utils.PAGE_SIZE,
            vmm.Attr{ .permissions = .ReadWrite },
        );
        const ustack_top = ustack_bottom + user_stack_pages * utils.PAGE_SIZE;

        // Context lives on kernel stack
        self.base.context = @ptrFromInt(self.base.kernel_stack - @sizeOf(Context));
        self.base.context.* = Context{
            .registers = .{},
            .interrupt_num = 0,
            .error_code = 0,
            .ret_frame = .{
                .rip = 0,
                .cs = 0x20 | 0x3,
                .rsp = ustack_top,
                .rflags = 0x202,
                .ss = 0x18 | 0x3,
            },
        };
    }

    pub fn loadElf(self: *UserTask, buffer: []align(@alignOf(std.elf.Elf64_Ehdr)) const u8) !void {
        const entry = try elf.load(buffer, self.pml4, &self.vma);
        self.base.context.ret_frame.rip = entry;
    }
};

pub const KernelEntryFn = fn (u64) i32;

pub const KernelTask = struct {
    base: Task,
    entry: *const KernelEntryFn,
    arg: u64,

    pub fn init(self: *KernelTask, kernel_stack_pages: usize, entry: KernelEntryFn, arg: u64) !void {
        self.base.kind = .Kernel;
        self.base.state = .Runnable;
        self.base.kernel_stack_pages = kernel_stack_pages;

        const kstack_base = try pmm.allocatePageBlock(kernel_stack_pages, .@"1") + globals.hhdm_offset;
        self.base.kernel_stack = kstack_base + kernel_stack_pages * utils.PAGE_SIZE;
        self.entry = &entry;
        self.arg = arg;

        self.base.context = @ptrFromInt(self.base.kernel_stack - @sizeOf(Context));
        self.base.context.* = Context{
            .registers = .{
            },
            .interrupt_num = 0,
            .error_code = 0,
            .ret_frame = .{
                .rip = @intFromPtr(&kernelTaskTrampoline),
                .cs = 0x08,
                .rsp = self.base.kernel_stack,
                .rflags = 0x202,
                .ss = 0x10,
            },
        };
    }
};
