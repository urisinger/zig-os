const root = @import("root");
const std = @import("std");
const arch = root.arch;
const tss = arch.tss;
const Context = arch.context.Context;
const globals = root.common.globals;
const elf = @import("exec/elf.zig");

const mem = root.mem;
const slab = mem.kheap.slab;
const paging = mem.kernel.paging;
const page_table = mem.page_table;
const VmAllocator = mem.user.vmm.VmAllocator;

const utils = root.common.utils;
const pmm = mem.pmm;
const uheap = mem.user.heap;

pub const Task = struct {
    context: *Context,
    pml4: *page_table.PageMapping,
    vma: VmAllocator,
    kernel_stack: u64,

    pub fn init(task: *Task, kernel_stack_pages: usize, user_stack_pages: usize) !void {
        task.pml4 = try paging.createNewAddressSpace();
        task.vma = try VmAllocator.init(utils.MB(1), 0x00007FFFFFFFFFFF);

        const kstack_base = try pmm.allocatePageBlock(kernel_stack_pages, .@"1") + globals.hhdm_offset;
        task.kernel_stack = kstack_base + kernel_stack_pages * utils.PAGE_SIZE;

        const ustack_bottom = try uheap.allocateUserPages(&task.vma, task.pml4, 3);
        const ustack_top = ustack_bottom + user_stack_pages * utils.PAGE_SIZE;

        task.context = @ptrFromInt(task.kernel_stack - @sizeOf(Context));
        task.context.* = Context{
            .registers = .{},
            .interrupt_num = 0,
            .error_code = 0,
            .ret_frame = .{
                .rip = 0xdeadbeef,
                .cs = 0x20 | 0x3,
                .rsp = ustack_top,
                .rflags = 0x202,
                .ss = 0x18 | 0x3,
            },
        };
    }

    pub fn loadElf(self: *Task, buffer: []align(@alignOf(std.elf.Elf64_Ehdr)) const u8) !void {
        const entry = try elf.load(buffer, self.pml4, &self.vma);
        self.context.ret_frame.rip = entry;
    }

    pub fn load(self: *Task) void {
        tss.set_rsp(self.kernel_stack);
        arch.getContext().kernel_stack = self.kernel_stack;
        arch.instr.setCr3(@intFromPtr(self.pml4) - globals.hhdm_offset);
    }
};
