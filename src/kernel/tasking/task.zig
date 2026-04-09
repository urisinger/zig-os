const root = @import("root");
const arch = root.arch;
const tss = arch.tss;
const Context = arch.context.Context;
const globals = root.common.globals;

const mem = root.mem;
const page_table = mem.page_table;
const VmaAllocator = mem.user.vmm.VmAllocator;

pub const Task = struct {
    context: *Context,
    pml4: *page_table.PageMapping,
    vma: VmaAllocator,
    kernel_stack: u64,

    pub fn load(task: *Task) void {
        tss.set_rsp(task.kernel_stack);
        arch.getContext().kernel_stack = task.kernel_stack;
        const pml4 = task.pml4;

        arch.instr.setCr3(@intFromPtr(pml4) - globals.hhdm_offset);
    }
};
