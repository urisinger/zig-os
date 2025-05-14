const std = @import("std");
const log = std.log.scoped(.elf);
const elf = std.elf;
const Header = elf.Header;

const utils = @import("../utils.zig");

const page_table = @import("../memory/page_table.zig");
const uvmm = @import("../memory/user/vmm.zig");

pub fn loadElf(buffer: []align(@alignOf(elf.Elf64_Ehdr)) const u8, pml4: *page_table.PageMapping, vmm: *uvmm.VmAllocator) !void {
    const header = try Header.parse(buffer[0..64]);

    log.debug("elf header: {}", .{header});

    var iter = header.program_header_iterator(std.io.fixedBufferStream(buffer));

    while (try iter.next()) |item| {
        switch (item.p_type) {
            elf.PT_LOAD => {
                log.debug("found loadable program header: {}", .{item});

                if (item.p_flags & elf.PF_X != 0) {
                    log.debug("program header is executable", .{});
                }

                if (item.p_flags & elf.PF_W != 0) {
                    log.debug("program header is writable", .{});
                }

                if (item.p_flags & elf.PF_R != 0) {
                    log.debug("program header is readable", .{});
                }

                const start = item.p_vaddr;
                const end = start + item.p_memsz;

                const page_count = (end - start) / utils.PAGE_SIZE;

                const pages = try vmm.allocatePages(page_count);

                try pml4.mapPages(start, pages, page_count, .user);
            },
            else => {},
        }
    }
}
