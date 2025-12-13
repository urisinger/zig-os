const std = @import("std");
const log = std.log.scoped(.elf);
const elf = std.elf;
const Header = elf.Header;

const slab = @import("../memory/kernel/slab.zig");

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
const Elf64_Phdr = elf.Elf64_Phdr;
const Elf32_Phdr = elf.Elf32_Phdr;

pub fn elfTask(buffer: []align(@alignOf(elf.Elf64_Ehdr)) const u8) !*Task {
    var user_vmm = try uvmm.VmAllocator.init(utils.MB(1), 0x00007FFFFFFFFFFF);

    const user_pml4 = paging.createNewAddressSpace() catch unreachable;

    const entry_point = loadElf(buffer, user_pml4, &user_vmm) catch unreachable;

    const user_stack_bottom = uheap.allocateUserPages(&user_vmm, user_pml4, 3) catch unreachable;
    const user_stack_top = user_stack_bottom + 3 * utils.PAGE_SIZE;

    const kernel_stack = try pmm.allocatePageBlock(2, .@"1") + globals.hhdm_offset;

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

    const task = try (try slab.get_slab_cache(Task)).alloc();

    task.* = Task{
        .context = context_ptr,
        .vma = user_vmm,
        .pml4 = user_pml4,
        .kernel_stack = kernel_stack_top,
    };

    return task;
}

pub fn loadElf(buffer: []align(@alignOf(elf.Elf64_Ehdr)) const u8, pml4: *page_table.PageMapping, vmm: *uvmm.VmAllocator) !u64 {
    var fixed = std.Io.Reader.fixed(buffer[0..64]);
    const header = try Header.read(&fixed);

    for (0..header.phnum) |index| {
        const size: u64 = if (header.is_64) @sizeOf(Elf64_Phdr) else @sizeOf(Elf32_Phdr);
        const offset = header.phoff + size * index;

        fixed = .fixed(buffer[offset .. buffer.len - 1]);
        const item = try takePhdr(&fixed, header);

        switch (item.p_type) {
            elf.PT_LOAD => {
                const page_size = utils.PAGE_SIZE;

                const file_offset_page = std.mem.alignBackward(u64, item.p_offset, page_size);
                const virt_base = std.mem.alignBackward(u64, item.p_vaddr, page_size);
                const virt_delta = item.p_vaddr - virt_base;

                const map_size = std.mem.alignForward(u64, item.p_memsz + virt_delta, page_size);

                try vmm.allocate_address(virt_base, map_size, .{
                    .permissions = if (item.p_flags & elf.PF_W != 0) .ReadWrite else if (item.p_flags & elf.PF_X != 0) .ReadExecute else .Read,
                });

                const read_write: page_table.ReadWrite =
                    if (item.p_flags & elf.PF_W != 0) .read_write else .read_execute;

                const num_pages = map_size / page_size;
                for (0..num_pages) |i| {
                    const vaddr = virt_base + i * page_size;
                    const paddr = try pmm.allocatePage();
                    const page_ptr: *align(page_size) [4096]u8 = @ptrFromInt(paddr + globals.hhdm_offset);

                    // If we are in file, copy to file buffer
                    const file_pos = file_offset_page + i * page_size;
                    const file_end = item.p_offset + item.p_filesz;

                    if (file_pos + page_size <= file_end) {
                        // full page copy
                        @memcpy(page_ptr, buffer[file_pos .. file_pos + page_size]);
                    } else if (file_pos < file_end) {
                        // partial page copy, zero the rest
                        const valid_bytes = file_end - file_pos;
                        @memcpy(page_ptr[0..valid_bytes], buffer[file_pos..file_end]);
                        @memset(page_ptr[valid_bytes..], 0);
                    } else {
                        // bss region (zero-initialized)
                        @memset(page_ptr, 0);
                    }

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

    log.info("PML4: {any}", .{pml4.getPaddr(@bitCast(@as(u64, 0xffff8000fee00000)))});

    return header.entry;
}

fn takePhdr(reader: *std.io.Reader, elf_header: Header) !Elf64_Phdr {
    if (elf_header.is_64) {
        const phdr = try reader.takeStruct(Elf64_Phdr, elf_header.endian);
        return phdr;
    }

    const phdr = try reader.takeStruct(Elf32_Phdr, elf_header.endian);
    return .{
        .p_type = phdr.p_type,
        .p_offset = phdr.p_offset,
        .p_vaddr = phdr.p_vaddr,
        .p_paddr = phdr.p_paddr,
        .p_filesz = phdr.p_filesz,
        .p_memsz = phdr.p_memsz,
        .p_flags = phdr.p_flags,
        .p_align = phdr.p_align,
    };
}
