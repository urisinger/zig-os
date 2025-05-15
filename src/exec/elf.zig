const std = @import("std");
const log = std.log.scoped(.elf);
const elf = std.elf;
const Header = elf.Header;

const utils = @import("../utils.zig");
const globals = @import("../globals.zig");

const page_table = @import("../memory/page_table.zig");
const uvmm = @import("../memory/user/vmm.zig");
const pmm = @import("../memory/pmm.zig");
const Task = @import("../scheduler/scheduler.zig").Task;
const kheap = @import("../memory/kernel/heap.zig");
const paging = @import("../memory/kernel/paging.zig");
const uheap = @import("../memory/user/heap.zig");
const idt = @import("../idt/idt.zig");

pub fn elfTask(buffer: []align(@alignOf(elf.Elf64_Ehdr)) const u8, allocator: std.mem.Allocator) !*Task {
    var user_vmm = uvmm.VmAllocator.init(allocator, utils.MB(1), 0x00007FFFFFFFFFFF);

    const user_pml4 = paging.createNewAddressSpace() catch unreachable;

    const entry_point = loadElf(buffer, user_pml4, &user_vmm) catch unreachable;

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
            .cs = 0x20 | 0x3,
            .rsp = user_stack_top,
            .rflags = 0x202,
            .ss = 0x18 | 0x3,
        },
    };

    const task = allocator.create(Task) catch unreachable;

    task.* = Task{
        .context = context_ptr,
        .vma = user_vmm,
        .pml4 = user_pml4,
        .kernel_stack = kernel_stack_top,
    };

    return task;
}

pub fn loadElf(buffer: []align(@alignOf(elf.Elf64_Ehdr)) const u8, pml4: *page_table.PageMapping, vmm: *uvmm.VmAllocator) !u64 {
    const header = try Header.parse(buffer[0..64]);

    log.debug("elf header: {}", .{header});

    var iter = header.program_header_iterator(std.io.fixedBufferStream(buffer));

    while (try iter.next()) |item| {
        switch (item.p_type) {
            elf.PT_LOAD => {
                const read_write: page_table.ReadWrite = if (item.p_flags & elf.PF_W != 0) .read_write else .read_execute;

                if (item.p_flags & elf.PF_X != 0) {
                    log.debug("program header is executable", .{});
                }

                if (item.p_flags & elf.PF_W != 0) {
                    log.debug("program header is writable", .{});
                }

                if (item.p_flags & elf.PF_R != 0) {}

                try vmm.allocate_address(item.p_vaddr, item.p_memsz, .{
                    .permissions = .ReadWrite,
                });

                const num_pages = item.p_memsz / utils.PAGE_SIZE;
                for (0..num_pages) |i| {
                    const vaddr = item.p_vaddr + i * utils.PAGE_SIZE;
                    const paddr = try pmm.allocatePage();
                    const page_ptr: *align(utils.PAGE_SIZE) [4096]u8 = @ptrFromInt(paddr + globals.hhdm_offset);

                    @memcpy(page_ptr, buffer[item.p_offset + i * utils.PAGE_SIZE .. item.p_offset + (i + 1) * utils.PAGE_SIZE]);

                    try pml4.mapPage(@bitCast(vaddr), paddr, .{
                        .present = true,
                        .read_write = read_write,
                        .user_supervisor = .user,
                    });
                }
            },
            else => {},
        }
    }

    return header.entry;
}
